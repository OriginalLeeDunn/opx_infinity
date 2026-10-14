--- The Player object, the roster it lives in, money, metadata and position.
-- @author dop42
--
-- A Player is a character that is in the world. `M.Players` is keyed by player id
-- and `M.Registry` is its reverse index, so that a lookup by citizen id or by
-- account is one hash read and never a walk.
--
-- A player id is recycled and a user id is durable, so a player id is only ever a
-- search key: every read re-checks the user id behind the slot. A departure
-- nobody reported becomes a non-event instead of a hole.
--
-- Sessions, the readiness gate and routing buckets belong to core: this module
-- owns the roster of loaded characters and nothing else about a connection.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

--- Every loaded character by player id.
M.Players = {}

--- Player ids by citizen id and by user id.
M.Registry = {
	byCitizenId = {},
	byUserId = {},
}

--- The public half of a character, as another resource is handed it.
-- @author dop42
--
-- BUILT, NEVER LENT. The export surface and the public bus both cross into
-- another resource's VM by copy, and a copy of the whole PlayerData would
-- publish everything any module ever hung off it -- metadata included, which is
-- free-form and is where a module keeps what it did not want on the wire. So the
-- creator surface is this closed list, and adding a field to it is a decision
-- somebody makes here.
-- @param player Player
-- @return table
function M.PublicView(player)
	local data = player.PlayerData
	local charInfo = type(data.charInfo) == 'table' and data.charInfo or {}
	return {
		source = data.source,
		citizenId = data.citizenId,
		userId = data.userId,
		firstName = charInfo.firstName,
		lastName = charInfo.lastName,
		money = OPX.Table.DeepCopy(data.money or {}),
		job = OPX.Table.DeepCopy(data.job),
		gang = OPX.Table.DeepCopy(data.gang),
		jobs = OPX.Table.DeepCopy(data.jobs or {}),
		gangs = OPX.Table.DeepCopy(data.gangs or {}),
	}
end

-- ── the offline ledger ───────────────────────────────────────────────────────
-- WHO IS WRITING A CHARACTER'S ROW WHILE NOBODY IS PLAYING IT.
--
-- A loaded character is written from memory, whole: `Storage.Save` puts the
-- money column back as PlayerData holds it. So any write to the row that does
-- not go through PlayerData is lost the moment a login that read the row BEFORE
-- it saves AFTER it -- and a login yields three times between its read and the
-- roster. `AddMoneyOffline` is such a write, and so is a staff rename of a
-- character nobody is playing, and so is a job or gang change (groups.lua).
--
-- `busy` counts writers on the row right now and `seq` moves every time one
-- finishes. A login notes `seq` before it reads, waits for `busy` to reach zero
-- before it registers, and reads the row again when `seq` moved: what it then
-- puts in the roster is what is in the database. A logout counts as a writer
-- from the moment the character leaves the roster until its last save lands, so
-- an offline write that arrives during that save waits for it instead of being
-- written underneath it.
local ledger = {}

-- How long an offline writer or a login waits for the row to be free.
local LEDGER_WAIT_MS = 10000
local LEDGER_POLL_MS = 50
-- How long a hold may last before it can only be a writer that died holding it.
local LEDGER_STALE_MS = 60000

M.Ledger = {}

--- The ledger entry of one citizen id, created on first use.
local function ledgerOf(citizenId)
	local entry = ledger[citizenId]
	if entry == nil then
		entry = { busy = 0, seq = 0 }
		ledger[citizenId] = entry
	end
	return entry
end

--- How many writes on a row have finished.
-- @author dop42
-- @param citizenId CitizenId
-- @return integer
function M.Ledger.Seen(citizenId)
	local entry = ledger[citizenId]
	return entry and entry.seq or 0
end

--- Whether a write on a row is under way.
-- @author dop42
--
-- A WRITER THAT NEVER LEFT IS FORGOTTEN, loudly. Every `Enter` in this module
-- is paired with a `Leave` on the same path, and the database calls between
-- them cannot raise; but a hold that outlived `LEDGER_STALE_MS` can only be a
-- path that died between the two, and honouring it for ever would refuse that
-- character's every login. The row is released and the journal says which.
-- @param citizenId CitizenId
-- @return boolean
function M.Ledger.Busy(citizenId)
	local entry = ledger[citizenId]
	if entry == nil or entry.busy <= 0 then return false end
	if OPX.Now() - (entry.since or 0) > LEDGER_STALE_MS then
		Open77.log.error(('[character] the offline ledger held %s for over %d ms; releasing it')
			:format(tostring(citizenId), LEDGER_STALE_MS))
		entry.busy = 0
		entry.seq = entry.seq + 1
		return false
	end
	return true
end

--- Counts a writer in, unconditionally. For a logout, which already owns the row.
-- @author dop42
-- @param citizenId CitizenId
function M.Ledger.Enter(citizenId)
	local entry = ledgerOf(citizenId)
	if entry.busy <= 0 then entry.since = OPX.Now() end
	entry.busy = entry.busy + 1
	entry.seq = entry.seq + 1
end

--- Counts a writer out, and says the row moved.
-- @author dop42
-- @param citizenId CitizenId
function M.Ledger.Leave(citizenId)
	local entry = ledger[citizenId]
	if entry == nil then return end
	entry.busy = math.max(0, entry.busy - 1)
	-- KEPT WHEN IDLE, not forgotten: a login that noted `seq` before a write
	-- began must still see it moved after the write ended, and a forgotten entry
	-- would answer 0 again -- the very number it noted. One small table per
	-- character ever written offline in this session is the price.
	entry.seq = entry.seq + 1
end

--- Waits until nobody is writing a row. Coroutine only.
-- @author dop42
-- @param citizenId CitizenId
-- @return boolean false when the wait ran out
function M.Ledger.Settle(citizenId)
	local deadline = OPX.Now() + LEDGER_WAIT_MS
	while M.Ledger.Busy(citizenId) do
		if OPX.Now() >= deadline then return false end
		Wait(LEDGER_POLL_MS)
	end
	return true
end

--- Whether a money type exists on this server.
-- @author dop42
-- @param moneyType any
-- @return boolean
function M.IsMoneyType(moneyType)
	return OPX.Config.SHARED.MONEY.TYPES[moneyType] ~= nil
end

--- Formats an amount for display with its currency.
-- @author dop42
-- @param amount number
-- @param moneyType MoneyType|nil
-- @return string
function M.FormatMoney(amount, moneyType)
	return OPX.Locale.Money(amount, moneyType)
end

--- Fills in whatever a stored entity is missing, in place.
-- So that a character written before a field existed loads instead of being
-- refused.
-- @author dop42
-- @param entity table
-- @return table
function M.NormaliseEntity(entity)
	local settings = M.Settings
	entity.charInfo = entity.charInfo or {}
	entity.metadata = entity.metadata or {}
	entity.money = entity.money or {}

	-- An absent currency is worth ZERO, not the configured starting amount: a
	-- starting amount is a new character's endowment.
	for moneyType in pairs(OPX.Config.SHARED.MONEY.TYPES) do
		entity.money[moneyType] = math.floor(tonumber(entity.money[moneyType]) or 0)
	end

	for key, value in pairs(settings.PLAYER.STARTING_METADATA) do
		-- Deep-copied: a default taken by reference would be one table shared by
		-- every character on the server.
		if entity.metadata[key] == nil then
			entity.metadata[key] = OPX.Table.DeepCopy(value)
		end
	end

	if type(entity.appearance) ~= 'table' then entity.appearance = nil end

	-- A job or gang dropped from the definitions falls back to the default one.
	-- The membership row is left intact, being edited or not.
	local job = M.Groups.ResolveJob(entity.job and entity.job.name, entity.job and entity.job.grade
		and entity.job.grade.level)
	if not job.ok then
		job = M.Groups.ResolveJob(settings.PLAYER.DEFAULT_JOB, 0)
	end
	entity.job = job.value

	local gang = M.Groups.ResolveGang(entity.gang and entity.gang.name,
		entity.gang and entity.gang.grade and entity.gang.grade.level)
	if not gang.ok then
		gang = M.Groups.ResolveGang(settings.PLAYER.DEFAULT_GANG, 0)
	end
	entity.gang = gang.value

	return entity
end

--- Builds a Player, with its Functions, around a stored entity.
-- @author dop42
-- @param entity table
-- @param offline boolean|nil An offline Player sends and places nothing.
-- @return Player
function M.CreatePlayer(entity, offline)
	local self = { Offline = offline == true }

	-- The dirty flag the autosave reads: incremented on every change, never reset,
	-- and moved nowhere but in UpdatePlayerData.
	self.Revision = 0

	-- False until the world agrees with the stored row. PlaceCharacter is the only
	-- thing that sets it true.
	self.MaySample = false

	self.PlayerData = M.NormaliseEntity(entity)

	-- An explicit `if`, not `offline and nil or entity.source`, which would answer
	-- `entity.source` in both branches.
	if self.Offline then
		self.PlayerData.source = nil
	else
		self.PlayerData.source = entity.source
	end

	local Functions = {}
	self.Functions = Functions

	function Functions.UpdatePlayerData()
		self.Revision = self.Revision + 1
		if self.Offline then return end
		TriggerClientEvent(M.Event.DATA, self.PlayerData.source, self.PlayerData)
		-- The whole of PlayerData to its owner above, and NOTHING to anybody else:
		-- never a name to a stranger (the owner's decision, see `server/state.lua`).
		-- The call stays so the bag of a slot reloaded over an older build is
		-- scrubbed of the keys that build replicated.
		M.State.Publish(self)
	end

	function Functions.SetPlayerData(key, value)
		if key == 'citizenId' or key == 'userId' or key == 'source' then
			error(('PlayerData.%s is identity and cannot be set'):format(key), 2)
		end
		self.PlayerData[key] = value
		Functions.UpdatePlayerData()
	end

	function Functions.SetMetaData(key, value)
		self.PlayerData.metadata[key] = value
		Functions.UpdatePlayerData()
	end

	function Functions.GetMetaData(key)
		if key == nil then return self.PlayerData.metadata end
		return self.PlayerData.metadata[key]
	end

	function Functions.SetCharInfo(key, value)
		self.PlayerData.charInfo[key] = value
		Functions.UpdatePlayerData()
	end

	-- The money, group, Save and Logout functions are the module-level mutators
	-- themselves, so a rule added to one is followed by both.
	function Functions.AddMoney(moneyType, amount, reason)
		return M.AddMoney(self, moneyType, amount, reason)
	end

	function Functions.RemoveMoney(moneyType, amount, reason)
		return M.RemoveMoney(self, moneyType, amount, reason)
	end

	function Functions.SetMoney(moneyType, amount, reason)
		return M.SetMoney(self, moneyType, amount, reason)
	end

	function Functions.GetMoney(moneyType)
		return M.GetMoney(self, moneyType)
	end

	function Functions.SetJob(name, grade)
		return M.Groups.SetJob(self, name, grade)
	end

	function Functions.SetGang(name, grade)
		return M.Groups.SetGang(self, name, grade)
	end

	function Functions.SetJobDuty(onDuty)
		return M.Groups.SetJobDuty(self, onDuty)
	end

	function Functions.Save()
		return M.Save(self)
	end

	function Functions.Logout()
		return M.Logout(self.PlayerData.source)
	end

	return self
end

--- Puts a loaded character into the roster and both indexes.
-- Any other occupant of the slot is dropped first: it means a second connection
-- raced this one.
-- @author dop42
-- @param player Player
function M.RegisterPlayer(player)
	local data = player.PlayerData
	local occupant = M.Players[data.source]
	if occupant and occupant ~= player then M.UnregisterPlayer(occupant) end
	M.Players[data.source] = player
	M.Registry.byCitizenId[data.citizenId] = data.source
	M.Registry.byUserId[data.userId] = data.source

	-- The bag carries nothing about a character any more (`server/state.lua`);
	-- clearing and publishing here scrubs a recycled slot of whatever an older
	-- build left on it.
	M.State.Clear(data.source)
	M.State.Publish(player)
end

--- Takes a character out of the roster and its own index entries.
-- An index entry goes only if it still points at this player: an account that
-- reconnects briefly has both its sessions in the roster.
-- @author dop42
-- @param player Player
function M.UnregisterPlayer(player)
	local data = player.PlayerData
	M.Players[data.source] = nil
	if M.Registry.byCitizenId[data.citizenId] == data.source then
		M.Registry.byCitizenId[data.citizenId] = nil
	end
	if M.Registry.byUserId[data.userId] == data.source then
		M.Registry.byUserId[data.userId] = nil
	end

	-- A DISCONNECT would not need this -- the bag dies with the session. This is
	-- the other unload: a character switch, or a logout back to a slot that stays
	-- connected, where the bag would otherwise go on naming somebody nobody is
	-- playing.
	M.State.Clear(data.source)
end

--- Answers the loaded character at a player id, or nil.
-- Nil for somebody still at the selection screen is not an error: that is a
-- session without a player.
-- @author dop42
-- @param source Source|string
-- @return Player|nil
function M.GetPlayer(source)
	return M.Players[tonumber(source) or -1]
end

--- Answers the loaded character carrying a citizen id, or nil.
-- @author dop42
-- @param citizenId CitizenId
-- @return Player|nil
function M.GetPlayerByCitizenId(citizenId)
	local source = M.Registry.byCitizenId[citizenId]
	return source and M.Players[source] or nil
end

--- Answers the loaded character of an account, or nil.
-- @author dop42
-- @param userId UserId
-- @return Player|nil
function M.GetPlayerByUserId(userId)
	local source = M.Registry.byUserId[userId]
	return source and M.Players[source] or nil
end

--- Lists every loaded character, evicting slots whose account changed.
-- This, not `pairs(M.Players)`, is the walk to use. Stale slots are collected
-- during the walk and evicted AFTER it: the logout handlers would otherwise
-- modify the table being iterated.
-- @author dop42
-- @return Player[]
function M.GetPlayers()
	local out, n = {}, 0
	local stale, staleCount = nil, 0

	for source, player in pairs(M.Players) do
		if OPX.UserIdOf(source) == player.PlayerData.userId then
			n = n + 1
			out[n] = player
		else
			staleCount = staleCount + 1
			stale = stale or {}
			stale[staleCount] = source
		end
	end

	for i = 1, staleCount do
		OPX.ForgetSession(stale[i])
	end
	return out
end

--- Counts the characters in the world without building a table.
-- @author dop42
-- @return integer
function M.GetPlayerCount()
	local n = 0
	for source, player in pairs(M.Players) do
		if OPX.UserIdOf(source) == player.PlayerData.userId then n = n + 1 end
	end
	return n
end

--- Resolves a Player, a player id or a citizen id to a Player.
-- The three shapes a caller can be holding.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Player|nil
function M.ResolvePlayer(identifier)
	if type(identifier) == 'table' and identifier.PlayerData then return identifier end
	if type(identifier) == 'number' then return M.GetPlayer(identifier) end
	if type(identifier) == 'string' then return M.GetPlayerByCitizenId(identifier) end
	return nil
end

local resolve = M.ResolvePlayer

--- Answers a character online, or its stored entity when offline.
-- The only reader here that reaches the database, so coroutine only.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.GetCharacter(citizenId)
	local online = M.GetPlayerByCitizenId(citizenId)
	if online then return Result.Ok({ player = online, offline = false }) end

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end
	return Result.Ok({ entity = fetched.value, offline = true })
end

-- THE MOST AN ACCOUNT HOLDS, either way: 2^53 - 1, the largest integer every
-- step of the trip survives -- Lua, the JSON column, the client's number. There
-- was no ceiling at all. `/opx.money <id> EDDIES 9000000000000000000` twice
-- wrapped the 64-bit sum to about -4.4e17, and `1e308` twice made the balance
-- `inf`, which no JSON encoder writes: the character stopped saving.
local MAX_BALANCE = 9007199254740991

--- Answers a positive, finite, rounded amount no larger than an account holds, or nil.
-- NaN arrives from a client through JSON and passes every comparison, including
-- the one that would stop the player spending it.
local function amountOf(value)
	local n = tonumber(value)
	if not OPX.Math.IsFinite(n) then return nil end
	n = math.floor(n + 0.5)
	if n <= 0 or n > MAX_BALANCE then return nil end
	return n
end

--- Whether a balance is one an account may hold.
local function holdable(balance)
	return balance <= MAX_BALANCE and balance >= -MAX_BALANCE
end

--- Whether a Player is still the one in the roster under its connection.
-- THE MONEY HOOKS MAY YIELD (`OPX.Hooks.Trigger` runs whatever a module hung on
-- them, and `character:loading` already reads the database from one), so the
-- world can move between the checks a mutator makes and the write it then does.
-- A Player that logged out during the hook has already been saved by its logout:
-- a balance changed on it afterwards is changed on a table nobody writes again,
-- and the shop that was told "paid" handed its goods over for nothing.
local function stillLoaded(player)
	return not player.Offline and M.Players[player.PlayerData.source] == player
end

--- Announces a balance change to its four audiences: the owning client, the
--- other modules, the audit log and PlayerData itself.
local function announceMoney(player, moneyType, amount, action, reason)
	local data = player.PlayerData
	player.Functions.UpdatePlayerData()

	TriggerClientEvent(M.Event.MONEY, data.source,
		moneyType, amount, action, data.money[moneyType])

	TriggerEvent(M.Event.IN_MONEY,
		data.source, data.citizenId, moneyType, amount, action, reason,
		data.money[moneyType])

	OPX.Audit.Player(player, 'money.' .. action, reason, {
		moneyType = moneyType,
		amount = amount,
		balance = data.money[moneyType],
	})

	-- The fifth audience: every other resource on the host. A reason is a
	-- caller's free text, so it is bounded on the way out like the audit bounds
	-- it on the way in.
	OPX.Publish(M.Event.ON_MONEY, data.source, {
		citizenId = data.citizenId,
		moneyType = moneyType,
		amount = amount,
		action = action,
		reason = reason ~= nil and OPX.Audit.Safe(reason, 128) or nil,
		balance = data.money[moneyType],
		offline = false,
	})
end

--- Adds money to a loaded character, hooked and audited.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.AddMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	-- No money column is ever written for a Player outside the roster.
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then
		Open77.log.error(('[character] AddMoney: %q is not a money type on this server')
			:format(tostring(moneyType)))
		return false, 'money.badType'
	end

	local value = amountOf(amount)
	if not value then
		OPX.Audit.Security('money.badAmount',
			('AddMoney refused %s'):format(tostring(amount)),
			{ citizenId = player.PlayerData.citizenId, moneyType = moneyType },
			player.PlayerData.source)
		return false, 'money.badAmount'
	end

	if not OPX.Hooks.Trigger('money:beforeAdd', {
		player = player, moneyType = moneyType, amount = value, reason = reason,
	}) then
		return false, 'money.vetoed'
	end
	if not stillLoaded(player) then return false, 'error.notLoggedIn' end

	local money = player.PlayerData.money
	-- Asked after the hook, on the balance the write will actually move.
	if not holdable(money[moneyType] + value) then return false, 'money.tooLarge' end
	money[moneyType] = money[moneyType] + value
	announceMoney(player, moneyType, value, 'add', reason)
	return true
end

--- Removes money, refusing rather than truncating when short.
-- A half-successful purchase is worse than one that fails.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.RemoveMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then
		Open77.log.error(('[character] RemoveMoney: %q is not a money type on this server')
			:format(tostring(moneyType)))
		return false, 'money.badType'
	end

	local value = amountOf(amount)
	if not value then
		OPX.Audit.Security('money.badAmount',
			('RemoveMoney refused %s'):format(tostring(amount)),
			{ citizenId = player.PlayerData.citizenId, moneyType = moneyType },
			player.PlayerData.source)
		return false, 'money.badAmount'
	end

	local money = player.PlayerData.money
	if money[moneyType] - value < 0
		and not OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] then
		return false, 'money.insufficient'
	end

	if not OPX.Hooks.Trigger('money:beforeRemove', {
		player = player, moneyType = moneyType, amount = value, reason = reason,
	}) then
		return false, 'money.vetoed'
	end

	-- ASKED AGAIN AFTER THE HOOK, which may yield (see `stillLoaded`). Two
	-- purchases in flight both passed the balance test above before either had
	-- subtracted; without this second look both subtract, and a balance of 100
	-- pays for two 100 items and ends at -100.
	if not stillLoaded(player) then return false, 'error.notLoggedIn' end
	if money[moneyType] - value < 0
		and not OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] then
		return false, 'money.insufficient'
	end
	-- Only reachable on a currency allowed to go negative.
	if not holdable(money[moneyType] - value) then return false, 'money.tooLarge' end

	money[moneyType] = money[moneyType] - value
	announceMoney(player, moneyType, value, 'remove', reason)
	return true
end

--- Sets a balance outright, zero included.
-- The only mutator that accepts zero, and so the only way to empty an account.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType
-- @param amount number
-- @param reason string|nil
-- @return boolean, string|nil A locale key naming the refusal.
function M.SetMoney(identifier, moneyType, amount, reason)
	local player = resolve(identifier)
	if not player then return false, 'error.notLoggedIn' end
	if player.Offline then return false, 'money.offline' end
	if not M.IsMoneyType(moneyType) then return false, 'money.badType' end

	local n = tonumber(amount)
	if not OPX.Math.IsFinite(n) then return false, 'money.badAmount' end
	n = math.floor(n + 0.5)
	if not holdable(n) then return false, 'money.tooLarge' end
	if n < 0 and not OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] then
		return false, 'money.negative'
	end

	if not OPX.Hooks.Trigger('money:beforeSet', {
		player = player, moneyType = moneyType, amount = n, reason = reason,
	}) then
		return false, 'money.vetoed'
	end
	if not stillLoaded(player) then return false, 'error.notLoggedIn' end

	player.PlayerData.money[moneyType] = n
	announceMoney(player, moneyType, n, 'set', reason)
	return true
end

--- Answers one balance, or the whole money table.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param moneyType MoneyType|nil
-- @return integer|table|nil
function M.GetMoney(identifier, moneyType)
	local player = resolve(identifier)
	if not player then return nil end
	if moneyType == nil then return player.PlayerData.money end
	return player.PlayerData.money[moneyType]
end

--- Adds money to a character whether or not anybody is playing it. Coroutine only.
-- @author dop42
--
-- THE ONLINE CHARACTER IS PAID THROUGH `AddMoney`, not through the row: an
-- autosave a minute later would write the loaded balance straight back over a
-- row edited underneath it, and the payment would simply undo itself. So this
-- is `AddMoney` for somebody who is here, and an atomic increment in SQL for
-- somebody who is not -- one statement, `JSON_SET` over the balance it read in
-- the same breath, so two offline payments never read the same old balance.
--
-- The row is held in the ledger above for the length of the write. A login
-- that read it first reads it again before it registers; a logout still saving
-- is waited for. A deleted character answers `character.notFound`, the same as
-- one that never existed. The `money:beforeAddOffline` hook may veto it: the
-- three online hooks are handed a live Player, which there is none of here, so
-- a hook written against them would index nil on this path.
-- @param citizenId CitizenId
-- @param moneyType MoneyType
-- @param amount number positive; rounded
-- @param reason string|nil
-- @return Result { balance, offline }
function M.AddMoneyOffline(citizenId, moneyType, amount, reason)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value
	if not M.IsMoneyType(moneyType) then return Result.Err('money.badType', tostring(moneyType)) end
	local value = amountOf(amount)
	if not value then return Result.Err('money.badAmount', tostring(amount)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	-- Whoever else is on the row goes first; a login is not one of them, and
	-- sees this write through `seq` instead.
	if not M.Ledger.Settle(citizenId) then
		return Result.Err('error.unavailable', 'the row is being written')
	end

	-- Asked AFTER the wait and with nothing between it and `Enter` that yields:
	-- a character that came online meanwhile is paid in memory, and one that did
	-- not cannot start writing from memory before this has finished.
	local online = M.GetPlayerByCitizenId(citizenId)
	if online ~= nil then
		local ok, code = M.AddMoney(online, moneyType, value, reason)
		if not ok then return Result.Err(code) end
		return Result.Ok({ balance = online.PlayerData.money[moneyType], offline = false })
	end

	if not OPX.Hooks.Trigger('money:beforeAddOffline', {
		citizenId = citizenId, moneyType = moneyType, amount = value, reason = reason,
	}) then
		return Result.Err('money.vetoed')
	end

	-- AND ASKED AGAIN AFTER THE HOOKS, WHICH MAY YIELD (`Hooks.Trigger` says so):
	-- a login that finished meanwhile has a character in the roster that will
	-- save the balance it loaded, and the increment below would land under it
	-- and be written over. Nothing between this and `Enter` yields.
	if not M.Ledger.Settle(citizenId) then
		return Result.Err('error.unavailable', 'the row is being written')
	end
	online = M.GetPlayerByCitizenId(citizenId)
	if online ~= nil then
		local ok, code = M.AddMoney(online, moneyType, value, reason)
		if not ok then return Result.Err(code) end
		return Result.Ok({ balance = online.PlayerData.money[moneyType], offline = false })
	end

	M.Ledger.Enter(citizenId)
	local written = M.Storage.AddMoney(citizenId, moneyType, value)
	local balance = written.ok and M.Storage.Balance(citizenId, moneyType) or nil
	M.Ledger.Leave(citizenId)
	if not written.ok then return written end

	OPX.Audit.Log({
		event = 'money.addOffline',
		message = reason,
		citizenId = citizenId,
		data = { moneyType = moneyType, amount = value,
			balance = balance and balance.ok and balance.value or nil },
	})
	OPX.Publish(M.Event.ON_MONEY, nil, {
		citizenId = citizenId,
		moneyType = moneyType,
		amount = value,
		action = 'add',
		reason = reason ~= nil and OPX.Audit.Safe(reason, 128) or nil,
		balance = balance and balance.ok and balance.value or nil,
		offline = true,
	})
	return Result.Ok({
		balance = balance and balance.ok and balance.value or nil,
		offline = true,
	})
end

--- Sets one key of a loaded character's free-form metadata.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param key string
-- @param value any
-- @return boolean
function M.SetMetadata(identifier, key, value)
	local player = resolve(identifier)
	if not player then return false end
	player.Functions.SetMetaData(key, value)
	return true
end

--- Answers one metadata key, or the whole metadata table.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param key string|nil
-- @return any
function M.GetMetadata(identifier, key)
	local player = resolve(identifier)
	if not player then return nil end
	return player.Functions.GetMetaData(key)
end

--- A character's whole metadata, online or not. Coroutine only for an offline
--- one: the row is read.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result { metadata, offline } -- the metadata a COPY
function M.ReadMetadata(citizenId)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value
	local online = M.GetPlayerByCitizenId(citizenId)
	if online ~= nil then
		return Result.Ok({ metadata = OPX.Table.DeepCopy(online.PlayerData.metadata or {}),
			offline = false })
	end
	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end
	return Result.Ok({ metadata = fetched.value.metadata or {}, offline = true })
end

--- Writes one metadata key of a character, online or not, held in the offline
--- ledger like `AddMoneyOffline`. Coroutine only.
-- `check(metadata)` is asked with the metadata as it stands at the moment of the
-- write -- read under the ledger for an offline row -- and a string answer
-- refuses the write with that code; it is how a caller bounds what it keeps
-- against what is really there rather than against a read made before a wait.
-- A character online is written in memory, through `SetMetadata`.
-- @author dop42
-- @param citizenId CitizenId
-- @param key string `[%w_%-%.]`, at most 128 bytes
-- @param value any plain data, or nil to remove the key
-- @param check fun(metadata: table): string|nil|nil
-- @return Result { offline }
function M.WriteMetadata(citizenId, key, value, check)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value
	if type(key) ~= 'string' or #key < 1 or #key > 128 or not key:match('^[%w_%-%.]+$') then
		return Result.Err('error.badRequest', 'key')
	end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local function online()
		local player = M.GetPlayerByCitizenId(citizenId)
		if player == nil then return nil end
		local refused = check and check(player.PlayerData.metadata or {}) or nil
		if refused ~= nil then return Result.Err(refused) end
		M.SetMetadata(player, key, OPX.Table.DeepCopy(value))
		return Result.Ok({ offline = false })
	end

	if not M.Ledger.Settle(citizenId) then
		return Result.Err('error.unavailable', 'the row is being written')
	end
	local live = online()
	if live ~= nil then return live end

	M.Ledger.Enter(citizenId)
	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then
		M.Ledger.Leave(citizenId)
		return fetched
	end
	local refused = check and check(fetched.value.metadata or {}) or nil
	if refused ~= nil then
		M.Ledger.Leave(citizenId)
		return Result.Err(refused)
	end
	local written = M.Storage.SetMetadataKey(citizenId, key, value)
	M.Ledger.Leave(citizenId)
	if not written.ok then return written end
	return Result.Ok({ offline = true })
end

--- Writes the two halves of a character's name, once. Coroutine only.
-- @author dop42
--
-- A character is a row before it is anybody: it is created with no name, built in
-- the game's own creator, and named by its player once they are in the world. So
-- this is the other half of `SetBodyFamily`, with the same rule -- WRITTEN ONCE.
-- A name is what everyone else in the city knows somebody by, and a character
-- that could be renamed is a character nobody can be held to.
-- @param identifier Player|Source|CitizenId
-- @param firstName any
-- @param lastName any
-- @return Result
function M.SetName(identifier, firstName, lastName)
	local player = resolve(identifier)
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end

	local first = M.ValidateName(firstName)
	if not first.ok then return Result.Err((M.NameRefusal(first)), 'firstName') end
	local last = M.ValidateName(lastName)
	if not last.ok then return Result.Err((M.NameRefusal(last)), 'lastName') end

	local charInfo = player.PlayerData.charInfo
	if charInfo.firstName ~= nil or charInfo.lastName ~= nil then
		return Result.Err('character.nameSet', tostring(charInfo.firstName))
	end

	charInfo.firstName = first.value
	charInfo.lastName = last.value
	player.Functions.UpdatePlayerData()

	OPX.Audit.Player(player, 'character.named', ('%s %s'):format(first.value, last.value))
	Open77.log.info(('[character] %s is %s %s'):format(player.PlayerData.citizenId,
		first.value, last.value))

	-- Written through rather than left to the autosave, for the same reason as the
	-- body: a character that comes back nameless would be asked for its name again
	-- as though nothing had been typed.
	local saved = M.Save(player, false)
	if not saved.ok then return saved end
	return Result.Ok({ firstName = first.value, lastName = last.value })
end

--- Writes the body family a character was built on, once. Coroutine only.
-- @author dop42
--
-- `charInfo.gender` is not asked for at creation: the engine's own character
-- creator asks for it, and this is where its answer lands. It is written ONCE,
-- because the family is the character -- a second writer would move somebody
-- already played onto another body, and the face stored against the first one
-- would then go on the wrong one. A second write is refused by name rather than
-- ignored, so a caller that thinks it owns the body learns that it does not.
-- @param identifier Player|Source|CitizenId
-- @param family string `female` or `male`
-- @return Result
function M.SetBodyFamily(identifier, family)
	local player = resolve(identifier)
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end
	if family ~= 'female' and family ~= 'male' then
		return Result.Err('character.badBody', tostring(family))
	end

	local charInfo = player.PlayerData.charInfo
	if charInfo.gender == family then return Result.Ok(family) end
	if charInfo.gender ~= nil then
		return Result.Err('character.bodySet', tostring(charInfo.gender))
	end

	player.Functions.SetCharInfo('gender', family)
	Open77.log.info(('[character] %s was built on the %s body')
		:format(player.PlayerData.citizenId, family))

	-- Written through rather than left to the autosave: this is the first thing a
	-- world entry reads about a character, and a server that stopped between here
	-- and the next autosave would bring it back with no body at all.
	local saved = M.Save(player, false)
	if not saved.ok then return saved end
	return Result.Ok(family)
end

--- Re-reads a character's position from the host, with the reported heading.
-- Heading is the only field kept from what the client reported: x, y and z come
-- from the server snapshot, so a client lying about them lies to nobody. The
-- sample is refused while MaySample is false, and refused when the user id behind
-- the player id has changed -- the id may have been recycled, and another
-- account's coordinates must never land in this row.
-- @author dop42
-- @param player Player
-- @return boolean
function M.SamplePosition(player)
	local data = player.PlayerData
	if not data.source then return false end
	if not player.MaySample then return false end
	if OPX.UserIdOf(data.source) ~= data.userId then return false end

	local snapshot = Open77.players.position(data.source)
	if type(snapshot) ~= 'table' or snapshot.x == nil then return false end

	local previous = data.position
	data.position = {
		x = snapshot.x,
		y = snapshot.y,
		z = snapshot.z,
		heading = data.reportedHeading or (previous and previous.heading) or 0.0,
		bucket = snapshot.bucket or 0,
	}
	return true
end

--- Loads a character the session owns into the roster. Coroutine only.
-- THE ORDER IS THE CONTRACT. The groups are read before the Player is built, the
-- Player is in the roster before the client is told, and the session is re-read
-- after the reads because the player may have left while we waited.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.Login(source, citizenId)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end

	if OPX.BootError then
		return Result.Err('error.unavailable', OPX.BootError)
	end

	-- Noted BEFORE the read: an offline write that finishes after this point is
	-- one the read below may not have seen. See the ledger above.
	local seen = M.Ledger.Seen(citizenId)

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end

	local entity = fetched.value
	-- Somebody else's character answers the SAME code as one that does not exist.
	-- "that is not yours" would be an existence oracle; the attempt is audited.
	if entity.userId ~= session.userId then
		OPX.Audit.Security('character.notYours',
			('player %d asked for %s'):format(source, citizenId),
			{ userId = session.userId, owner = entity.userId }, source)
		return Result.Err('character.notFound', citizenId)
	end

	-- Two Players writing one row is the last save winning in silence.
	local already = M.GetPlayerByCitizenId(citizenId)
	if already and already.PlayerData.source ~= source then
		return Result.Err('character.inUse', citizenId)
	end

	local groups = M.Storage.FetchGroups(citizenId)
	if not groups.ok then return groups end

	-- Another read used to sit here, and other modules hang theirs on this hook.
	-- It yields exactly where that read did, which is what makes the session
	-- re-read below meaningful. The verdict is ignored on purpose: loading extras
	-- never refuses a login, and an unreadable row gives nil, which is neither
	-- worn nor saved by anybody.
	local extras = { citizenId = citizenId, entity = entity, data = {} }
	OPX.Hooks.Trigger('character:loading', extras)

	-- AN OFFLINE WRITE THAT RACED THIS LOGIN IS READ BACK, NOT SAVED OVER. A
	-- payment that landed on the row after the read above would otherwise be
	-- erased by this character's first save, which writes the balance it was
	-- loaded with. Bounded: a row that never settles refuses the login rather
	-- than loading a balance known to be stale. Re-read whole, because a staff
	-- rename is the other writer and it moves `charInfo`, not money.
	for _ = 1, 4 do
		if not M.Ledger.Settle(citizenId) then
			return Result.Err('error.unavailable', 'the character row is being written')
		end
		if M.Ledger.Seen(citizenId) == seen then break end
		seen = M.Ledger.Seen(citizenId)
		local again = M.Storage.FetchOne(citizenId)
		if not again.ok then return again end
		entity = again.value
		extras.entity = entity
		-- The memberships too: an offline job or gang change (groups.lua) is
		-- the third writer, and it moves the membership rows beside the column.
		local regrouped = M.Storage.FetchGroups(citizenId)
		if not regrouped.ok then return regrouped end
		groups = regrouped
	end
	if M.Ledger.Busy(citizenId) or M.Ledger.Seen(citizenId) ~= seen then
		return Result.Err('error.unavailable', 'the character row would not settle')
	end

	-- The session is re-read after those reads: if the player left while we waited
	-- (departing, or another session on the slot), the login is refused before
	-- anything is registered. The departure's own Logout has already run and would
	-- not run again, so the ghost would sit in the roster until the autosave
	-- evicted it, its reconnecting owner would be told `character.inUse`, and a
	-- recycled player id would inherit its PlayerData.
	if OPX.Sessions[source] ~= session or session.departing then
		return Result.Err('entry.noIdentity', tostring(source))
	end

	entity.source = source
	local player = M.CreatePlayer(entity, false)
	player.PlayerData.jobs = groups.value.jobs
	player.PlayerData.gangs = groups.value.gangs

	-- THE MEMBERSHIP ROW IS THE GRADE. The worked job's grade is stored twice --
	-- in the character's own `job` column and in its membership row -- and a
	-- change made while the character was away reaches only the row: a boss who
	-- promotes somebody offline moves their membership, because nobody is loaded
	-- to move the column with. Read back as it was, the column paid and gated the
	-- old rank until the next change of job. The row wins, and the next save
	-- writes the column to match. (Duty is the job's default either way: a
	-- session always starts there.)
	local worked = player.PlayerData.job
	local held = type(worked) == 'table' and type(player.PlayerData.jobs) == 'table'
		and tonumber(player.PlayerData.jobs[worked.name]) or nil
	if held ~= nil and type(worked.grade) == 'table' and held ~= worked.grade.level then
		local regraded = M.Groups.ResolveJob(worked.name, held)
		if regraded.ok then
			Open77.log.info(('[character] %s: %s grade %s on the record, %d on the roster; the roster wins')
				:format(citizenId, tostring(worked.name), tostring(worked.grade.level), held))
			player.PlayerData.job = regraded.value
		end
	end
	for key, value in pairs(extras.data) do player.PlayerData[key] = value end

	M.RegisterPlayer(player)
	session.citizenId = citizenId

	TriggerClientEvent(M.Event.LOADED, source, player.PlayerData)
	TriggerEvent(M.Event.IN_LOADED, source, player.PlayerData)
	OPX.Publish(M.Event.ON_LOADED, source, M.PublicView(player))

	OPX.Audit.Player(player, 'character.login', 'logged in')
	Open77.log.info(('[character] %s (%s) logged in as %s %s'):format(
		session.displayName, citizenId,
		player.PlayerData.charInfo.firstName or '?',
		player.PlayerData.charInfo.lastName or '?'))

	return Result.Ok(player)
end

--- Writes a character back, sampling its position first. Coroutine only.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param loggedOut boolean|nil Stamps last_logged_out.
-- @return Result
function M.Save(identifier, loggedOut)
	local player = resolve(identifier)
	if not player then return Result.Err('error.notLoggedIn') end

	-- A CHARACTER THAT HAS LEFT THE ROSTER IS WRITTEN BY ITS LOGOUT AND NOBODY
	-- ELSE. The autosave, `opx.save` and the stop sweep walk a snapshot of the
	-- roster and yield between saves, so they can reach a Player whose logout
	-- has already saved it and handed the row back to the ledger -- and an
	-- offline payment that landed since would be written over with the balance
	-- that Player was holding. Only the logout's own save (`loggedOut`) may
	-- write a Player that is no longer registered under its connection.
	if not player.Offline and not loggedOut and M.Players[player.PlayerData.source] ~= player then
		return Result.Err('error.notLoggedIn', 'no longer in the roster')
	end

	if not player.Offline then M.SamplePosition(player) end

	local saved = M.Storage.Save(player.PlayerData, loggedOut)
	if not saved.ok then
		Open77.log.error(('[character] save failed for %s: %s')
			:format(player.PlayerData.citizenId, tostring(saved.detail)))
	end
	return saved
end

-- ── THE CYBERWARE IDENTITY ────────────────────────────────────────────────────
-- `wiki/cyberware.md`: every implant transaction runs "on their own
-- already-bound character", and the binder is the CHARACTER ADAPTER. This
-- server runs no `open77_appearance` adapter -- THIS workflow is the trusted
-- character workflow the wiki names ("the selected character key must come
-- from your trusted character workflow"), so it binds the key it owns and
-- nothing else. The wiki's "do not combine a second identity binder with the
-- existing adapter" is honoured exactly: when an adapter resource is running,
-- this stands down and lets it bind.
--
-- Without a binder the shop is dead in the quietest possible way: `current`
-- reads "loading" for ever, every offer is refused `notReady`, and no log on
-- the server says anything happened. That is what "the menu does not equip"
-- looked like.

-- source -> true, the bindings this workflow took (and only its own).
local cyberwareBound = {}
-- source -> { at, citizenId, outcome, reason }: the LAST thing the binder did
-- for a connection, bound or not, so a "record not ready" can be diagnosed
-- from what actually happened instead of guessed at.
local cyberwareBinding = {}
-- Whether the stopped support resource has been said out loud this boot.
local warnedSupport = false

--- Whether a character adapter resource is running -- the wiki's binder. When
--- one is, this workflow stands down.
-- @return boolean
-- @return string|nil the adapter's name
local function adapterPresent()
	if type(GetResourceState) ~= 'function' then return false end
	for _, name in ipairs({ 'open77_appearance', 'opx77_appearance' }) do
		local ran, state = pcall(GetResourceState, name)
		if ran and state == 'running' then return true, name end
	end
	return false
end

--- The support resource's state, as the host reports it.
-- @return string
local function supportState()
	if type(GetResourceState) ~= 'function' then return 'unknown' end
	local ran, state = pcall(GetResourceState, 'open77_cyberware')
	return ran and tostring(state) or 'unknown'
end

--- Notes what the binder did for one connection.
-- @param source number
-- @param citizenId string|nil
-- @param outcome string `bound`, `skipped` or `refused`
-- @param reason string|nil
local function note(source, citizenId, outcome, reason)
	cyberwareBinding[source] = {
		at = OPX.Now(), citizenId = citizenId, outcome = outcome, reason = reason,
	}
end

--- Binds the platform's cyberware identity to the character key this workflow
-- owns. Idempotent per session, and LOUD where it cannot bind: every implant,
-- deck, dash and overdrive on this server waits on this one call, so a binder
-- that stood down in silence made the whole clinic answer "not ready" with
-- nothing in any log to say why.
-- @author XEROX710
-- @param source number
-- @param citizenId string|nil
function M.BindCyberware(source, citizenId)
	if cyberwareBound[source] then return end
	local present, adapter = adapterPresent()
	if present then
		return note(source, citizenId, 'skipped', 'adapter:' .. tostring(adapter))
	end
	local state = supportState()
	if state ~= 'running' and state ~= 'unknown' then
		if not warnedSupport then
			warnedSupport = true
			Open77.log.warn(('[character] open77_cyberware is %s: no character can be bound ' ..
				'for chrome, so every implant is refused "not ready" -- add it to resources.load')
				:format(state))
		end
		return note(source, citizenId, 'skipped', 'open77_cyberware:' .. state)
	end
	local api = type(Open77) == 'table' and Open77.cyberware or nil
	if api == nil or type(api.bind) ~= 'function' then
		return note(source, citizenId, 'skipped', 'no_bind_api')
	end
	if type(citizenId) ~= 'string' or citizenId == '' then
		return note(source, citizenId, 'skipped', 'no_citizen')
	end
	local ran, ok, reason = pcall(api.bind, source, citizenId)
	-- TRUTHY, NOT `== true`. The platform answers a mutation with a TABLE
	-- (`{ok=true}`) or `nil, reason` -- the official adapter reads it as
	-- `if ok then` -- and a strict `== true` called every successful bind a
	-- refusal, logged a table address as its reason and bound again on every
	-- placement.
	local accepted = ran and ok ~= nil and ok ~= false
		and not (type(ok) == 'table' and ok.ok == false)
	if accepted then
		cyberwareBound[source] = true
		return note(source, citizenId, 'bound', nil)
	end
	local why = tostring((ran and (reason or (type(ok) == 'table' and (ok.reason or ok.error))))
		or ok or 'refused')
	note(source, citizenId, 'refused', why)
	if ran and why == 'cyberware_storage_unavailable' then
		-- The platform's own quiet case: said once per boot, not per join.
		if not warnedSupport then
			warnedSupport = true
			Open77.log.warn('[character] the cyberware store is unavailable ' ..
				'(cyberware_storage_unavailable): implants cannot be fitted until the ' ..
				'server has a database for open77_cyberware')
		end
		return
	end
	Open77.log.warn(('[character] the cyberware identity of %s was refused: %s')
		:format(tostring(citizenId), why))
end

--- Binds again: the platform's `bind` on a binding that FAILED (a restore
--- that timed out, a store read that failed) starts it over, and on a healthy
--- one answers ok and changes nothing -- so asking again is always safe, and
--- it is the one lever a "not ready" record has.
-- @author XEROX710
-- @param source number
-- @return table the binding note after the attempt
function M.RebindCyberware(source)
	source = tonumber(source)
	if source == nil then return nil end
	local player = M.Players[source]
	local citizenId = player ~= nil and player.PlayerData ~= nil and player.PlayerData.citizenId or nil
	cyberwareBound[source] = nil
	M.BindCyberware(source, citizenId)
	return cyberwareBinding[source]
end

--- What the binder last did for a connection, and the support resource's
--- state, for a diagnosis.
-- @author XEROX710
-- @param source number
-- @return table
function M.CyberwareStatus(source)
	source = tonumber(source)
	local binding = source ~= nil and cyberwareBinding[source] or nil
	local present, adapter = adapterPresent()
	return {
		bound = source ~= nil and cyberwareBound[source] == true,
		outcome = binding ~= nil and binding.outcome or 'never',
		reason = binding ~= nil and binding.reason or nil,
		citizenId = binding ~= nil and binding.citizenId or nil,
		ageMs = binding ~= nil and (OPX.Now() - binding.at) or nil,
		support = supportState(),
		adapter = present and adapter or nil,
	}
end

--- Releases the binding this workflow took. Idempotent, and never anybody
-- else's.
-- @author XEROX710
-- @param source number
function M.UnbindCyberware(source)
	cyberwareBinding[source] = nil
	if not cyberwareBound[source] then return end
	cyberwareBound[source] = nil
	local api = type(Open77) == 'table' and Open77.cyberware or nil
	if api ~= nil and type(api.unbind) == 'function' then
		pcall(api.unbind, source)
	end
end

--- Takes a loaded character out of the roster and announces it.
local function unload(source)
	local player = source and M.Players[source]
	if not player then return nil end

	-- The identity goes with the character it names.
	M.UnbindCyberware(source)
	M.UnregisterPlayer(player)
	-- The row is this departure's until its last save lands: an offline write
	-- arriving in between would be written underneath that save and erased by
	-- it. Both callers below leave the ledger once they have saved.
	M.Ledger.Enter(player.PlayerData.citizenId)

	-- THE SLOT MAY NOT BE THIS PLAYER'S ANY MORE. Core's `session:forgotten`
	-- reaches the logout a tick after the session went, by which time a recycled
	-- slot can hold another account's fresh session: its `citizenId` is not this
	-- character's to clear, and the UNLOADED screen is not theirs to be shown.
	-- Everything addressed to the SLOT below waits on the account still being
	-- the one this Player was loaded for; the roster, the ledger and the
	-- in-VM announcements are about the character and always go.
	local session = OPX.Sessions[source]
	local holds = session ~= nil and session.userId == player.PlayerData.userId
	if holds then session.citizenId = nil end

	if holds then TriggerClientEvent(M.Event.UNLOADED, source) end
	TriggerEvent(M.Event.IN_UNLOADED, source, player.PlayerData)
	OPX.Publish(M.Event.ON_UNLOADED, source, {
		citizenId = player.PlayerData.citizenId,
		userId = player.PlayerData.userId,
	})
	return player
end

--- Unloads a character and dispatches its save, idempotently.
-- Idempotent because both departure events can arrive for the same departure.
-- THE ORDER IS THE CONTRACT. The Player leaves the roster BEFORE the save, which
-- yields: otherwise a lookup would answer "still here" during the write. The
-- position is sampled immediately and not inside the save, because the move that
-- follows would store it in the selection bucket.
-- @author dop42
-- @param source Source
function M.Logout(source)
	source = tonumber(source)
	local player = unload(source)
	if not player then return end

	-- Under pcall, because `unload` entered the ledger and only the save below
	-- leaves it: a raise here would otherwise hold the row until the stale guard.
	local settled, failure = pcall(function()
		M.SamplePosition(player)
		player.MaySample = false
		-- The account it was loaded for, so a recycled slot's new holder is
		-- never moved into a selection bucket for somebody else's logout.
		OPX.Buckets.Isolate(source, 'unloaded', player.PlayerData.userId)
	end)
	if not settled then
		Open77.log.error(('[character] logout of %s raised before its save: %s')
			:format(player.PlayerData.citizenId, tostring(failure)))
	end

	CreateThread(function()
		M.Save(player, true)
		M.Ledger.Leave(player.PlayerData.citizenId)
		OPX.Audit.Player(player, 'character.logout', 'logged out')
	end)
end

--- Unloads a character and waits for its row to be written.
-- What a character switch needs: Logout dispatches, and the read of the next
-- character would beat that thread to the database.
-- @author dop42
-- @param source Source
-- @return Result
function M.LogoutAndWait(source)
	source = tonumber(source)
	local player = unload(source)
	if not player then return Result.Ok(false) end

	local saved = M.Save(player, true)
	M.Ledger.Leave(player.PlayerData.citizenId)
	OPX.Audit.Player(player, 'character.logout', 'logged out')
	return saved
end
