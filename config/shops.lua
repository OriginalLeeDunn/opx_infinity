--- Clothing shops: where they stand, what a change costs, and what they offer.
-- @author dop42
--
-- A SHOP IS A PLACE THAT OPENS THE FITTING ROOM AND SENDS A BILL. It owns no
-- catalogue of its own and stocks nothing: the garments a player can wear are
-- whatever `Open77.equipment.records` answers for their body, which is a CLIENT
-- read the server cannot make. That is the fact this whole file is shaped
-- around, and it is why the price is per SLOT and not per garment -- the server
-- cannot price a jacket it is not able to see, but it can price "you changed
-- what is on your legs", because the slot names are a closed set it shares with
-- the client.
--
-- SO THE BILL IS COUNTED, NOT LOOKED UP. Close the room having changed your
-- legs and your feet, and you are charged `PRICES.Legs + PRICES.Feet`. Change
-- nothing and you are charged nothing. Change the same slot four times before
-- you save and you are charged once, because what is billed is the difference
-- between what you walked in wearing and what you walked out wearing.
--
-- THE CLIENT NEVER NAMES A PRICE. It reports which slots differ; the server
-- reads its own table. A client that claimed a total, or claimed a slot was
-- free, would be a client setting its own prices.

OPX.Config.MODULES.shops = {
	enabled = true,

	-- What one changed slot costs, in EDDIES, at a shop that does not say
	-- otherwise. A slot absent from this table is FREE -- which is how underwear
	-- is free everywhere below. A shop's own PRICES can only add to or change
	-- this table, never take a slot out of it, so a free slot at one shop is a 0
	-- in that shop's override, and a free shop is a 0 for every slot (or
	-- CHARGE = false, which frees every shop).
	--
	-- The nine slot names are the platform's own and are not ours to rename:
	-- Head, Face, InnerChest, OuterChest, Legs, Feet, Outfit, UnderwearTop,
	-- UnderwearBottom. A name that is not one of those is dropped at boot with a
	-- line naming it, because a typo that silently prices nothing is a shop that
	-- silently gives clothes away.
	PRICES = {
		Head = 250,
		Face = 250,
		InnerChest = 400,
		OuterChest = 600,
		Legs = 450,
		Feet = 300,
		-- A full outfit overrides the seven visible slots at once, so it is
		-- priced as the wardrobe change it is rather than as one more garment.
		Outfit = 900,
	},

	-- Whether a shop charges at all. False anywhere makes every room that shop
	-- opens free, which is what a starter district or a test server wants; the
	-- prices above are left in place so turning it back on needs no re-typing.
	CHARGE = true,

	-- The money type a bill is taken from. `EDDIES` is cash, `BANK` is the
	-- account; see `config/shared.lua` for the pair.
	CURRENCY = 'EDDIES',

	-- Metres a player may stand from a shop and still be served.
	--
	-- CHECKED AGAIN ON THE SERVER, not only here: the client asks, and a client
	-- can ask from anywhere. This is the radius of the target sphere AND the
	-- reach the server re-measures before it opens anything or takes any money.
	-- Generous enough that walking half a step does not refuse the sale.
	REACH = 3.0,

	-- The shops themselves, keyed by a durable slug. THE KEY IS WRITTEN INTO
	-- NOTHING PERSISTENT today, but it is what an audit line names and what a
	-- saved look may one day be bought at, so rename one only deliberately.
	--
	-- Each entry:
	--   LABEL     what the target row says
	--   X, Y, Z   where it stands
	--   BUCKET    routing bucket; 0 when omitted. A shop serves its own bucket
	--             only -- there is no "every bucket".
	--   PRICES    an override table; merged OVER the defaults above, so a shop
	--             states only what it charges differently. An empty table
	--             changes nothing; a slot set to 0 is free at that shop.
	--   JOBS      { job = minimumGrade }, or nil for anybody. A shop nobody but
	--             a ripperdoc may use is a shop for uniforms.
	--   ON_DUTY   true to require the job above to be on duty as well
	SHOPS = {
		jinguji = {
			LABEL = 'Jinguji',
			X = -1631.0, Y = -1012.0, Z = 8.0,
			BUCKET = 0,
		},

		-- Cheaper, and the underwear is free everywhere so it is not repeated.
		thrift_watson = {
			LABEL = 'Second-hand, Watson',
			X = -1180.0, Y = 1550.0, Z = 25.0,
			PRICES = { Head = 80, Face = 80, InnerChest = 120, OuterChest = 180,
				Legs = 140, Feet = 100, Outfit = 300 },
		},
	},

	-- Saved looks a player keeps, and the codes that move them between players.
	OUTFITS = {
		-- How many a character may keep. A ceiling and not a guess: the rows are
		-- one JSON blob each and the list is read whole every time it is shown.
		MAX_PER_CHARACTER = 24,

		-- Bytes a saved name may run to, before it is cut.
		MAX_NAME_BYTES = 48,

		-- Whether a look may be shared at all. False stops codes being minted
		-- and stops them being redeemed; the looks already saved keep working.
		--
		-- A code is redeemed ONLY inside a shop's fitting room, at its counter,
		-- and the pieces it puts on are billed at that shop's `PRICES` when the
		-- room is saved, exactly as if picked from its racks (the owner's ruling,
		-- 2026-10). It used to dress the player for free, anywhere.
		SHARING = true,

		-- Characters in a share code, excluding its dashes.
		--
		-- EIGHT FROM AN ALPHABET OF THIRTY-TWO is forty bits, which is not a
		-- secret and is not meant to be one: a code is a thing you read out to
		-- somebody, and it names a look that is public the moment you wear it.
		-- The alphabet leaves out the four characters people mistype when
		-- reading aloud.
		CODE_LENGTH = 8,
	},

	-- Looks the server offers ready-made, which is what makes a uniform
	-- possible. A player at a shop that carries one can put it on in a single
	-- choice instead of finding seven garments.
	--
	-- THESE ARE NOT PRICED BY SLOT. A ready-made look states its own COST, once,
	-- because it is one purchase and not a rummage -- and a uniform a job hands
	-- out states `COST = 0`, which is the point of it. It is billed when the
	-- room is SAVED with the look on, not when it is picked: a Cancel costs
	-- nothing, and the fitting room's status line shows the bill before Save.
	--
	-- `WEAR` is a partial record: the slots it names are set, and the slots it
	-- does NOT name are left exactly as the player already had them. `false`
	-- empties a slot. Records are TweakDB names, `Items.<something>`; a name
	-- this body cannot wear is skipped by the client with a line, because the
	-- two body families do not share every garment.
	-- ── EVERY RECORD HERE IS THE GAME'S OWN ───────────────────────────────
	--
	-- Read out of the two TweakDB files the install carries, through the
	-- platform's generated catalogue of all 1,991 wearable `Clo_*` records
	-- (`docs/research/clothing-items-catalog.md` and the JSON beside it), and
	-- each one checked for the slot it really belongs to AND for being on both
	-- body families. The four records the NCPD uniform used to name --
	-- `Items.Police_Jacket_01`, `Items.Police_Pants_01`, `Items.Police_Boots_01`
	-- and `Items.Q005_Police_Shirt` -- DO NOT EXIST, and neither did the four
	-- the corporate look named: both looks dressed NOTHING, and said nothing
	-- about it, because a record a body cannot wear is skipped with a log line
	-- rather than refused. A uniform that silently does nothing is the exact
	-- failure this file cannot test for itself, which is why `tests/run.lua`
	-- pins every name below.
	--
	-- WHAT THE GAME ACTUALLY HAS, exhaustively:
	--   NCPD  `Items.Cop_01_Set_*` -- jacket, pants, boots, glasses -- plus the
	--         questline's one-piece issue suit, `Items.SQ029_Police_Suit`.
	--   MaxTac `Items.SQ030_MaxTac_Helmet`, `_Chest`, `_Pants`. Three records
	--         and no fourth: there is no MaxTac boot, glove or undershirt that a
	--         player can wear, so those slots are left AS THE PLAYER HAD THEM --
	--         `false` would send a trooper out barefoot to no purpose.
	--   Trauma Team `Items.Trauma_Team_Outfit`, one piece, for the same job.
	LOOKS = {
		ncpd_patrol = {
			LABEL = 'NCPD patrol uniform',
			-- Who may take it. Same shape as the elevator floors: job to the
			-- minimum grade. Nil means anybody at a shop that lists it.
			JOBS = { ncpd = 0 },
			ON_DUTY = true,
			COST = 0,
			-- Which shops offer it. Nil means every shop, and every fitting room
			-- the panel opens, because the wardrobe draws the looks the server
			-- says this player may take -- so a uniform is not tied to one store.
			AT = nil,
			WEAR = {
				OuterChest = 'Items.Cop_01_Set_Jacket',
				Legs = 'Items.Cop_01_Set_Pants',
				Feet = 'Items.Cop_01_Set_Boots',
				Face = 'Items.Cop_01_Set_Glasses',
			},
		},

		-- The other half of the NCPD's kit, and its own look rather than a second
		-- name for the first: a one-piece issue suit and a four-piece patrol set
		-- are different things to a player standing in the room.
		ncpd_issue_suit = {
			LABEL = 'NCPD issue suit',
			JOBS = { ncpd = 0 },
			ON_DUTY = true,
			COST = 0,
			AT = nil,
			WEAR = { Outfit = 'Items.SQ029_Police_Suit' },
		},

		-- The division that answers at five stars, in the armour the game gives
		-- its own troopers: helmet, chest, pants.
		maxtac_field_kit = {
			LABEL = 'MaxTac field kit',
			JOBS = { maxtac = 0 },
			ON_DUTY = true,
			COST = 0,
			AT = nil,
			WEAR = {
				Head = 'Items.SQ030_MaxTac_Helmet',
				OuterChest = 'Items.SQ030_MaxTac_Chest',
				Legs = 'Items.SQ030_MaxTac_Pants',
			},
		},

		trauma_team = {
			LABEL = 'Trauma Team kit',
			JOBS = { trauma = 0 },
			ON_DUTY = true,
			COST = 0,
			AT = nil,
			WEAR = { Outfit = 'Items.Trauma_Team_Outfit' },
		},

		corpo_black = {
			LABEL = 'Corporate black',
			COST = 2500,
			WEAR = {
				InnerChest = 'Items.FormalShirt_01_basic_01',
				OuterChest = 'Items.FormalJacket_01_basic_01',
				Legs = 'Items.FormalPants_01_basic_01',
				Feet = 'Items.FormalShoes_01_basic_01',
				Head = false,
				Face = false,
			},
		},
	},
}
