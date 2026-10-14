--- Holocalls: player to player, the call owned by the server.
-- @author dop42
--
-- The owner calls it "appel vision". It is Cyberpunk's own holocall, wired
-- between two -- or three -- connected players instead of between V and a quest
-- NPC: somebody places a call, the other party's hologram sphere pops at the
-- bottom of the view with the caller's name in it, and they answer or refuse it
-- on a key without opening anything. While the call runs both parties' eyes
-- carry the game's authored blue glow.
--
-- THE CALL IS A SERVER OBJECT AND THE CLIENT DECIDES NOTHING. That is not a
-- style rule here, it is what makes the feature possible at all: two machines
-- are involved and neither may be believed about what the other agreed to. A
-- client says "I pressed accept" and the server says who is in the call, who
-- may be added, whose eyes are lit and when the whole thing ends. Every screen
-- in this module is drawn from a state the server pushed.
--
-- THREE THINGS NEED CONSENT AND THERE IS ONE MECHANISM FOR ALL THREE. Placing a
-- call, adding a third participant and handing over a contact are the same
-- shape -- somebody asks, somebody else agrees or does not -- so they are one
-- object, an INVITE with a `kind`, and one accept/decline pair. The first
-- sketch had three verb families and three refusal vocabularies; they disagreed
-- about the cooldown within an hour of being written.
--
--   invite(kind = call)     nobody is in a call yet; accepting creates one
--   invite(kind = join)     the sender is in a call; accepting adds the target
--   invite(kind = contact)  no call at all; accepting swaps contact rows
--
-- ONE CALL AT A TIME, ONE INVITE OUT, ONE INVITE IN. A player is in at most one
-- call, has at most one invite outstanding and at most one waiting for an
-- answer. The last of the three is the one that is really a UI decision made
-- honest: the sphere shows ONE incoming call, so a second would have to be
-- queued, stacked or dropped -- and a queue of calls somebody never sees is
-- worse than a refusal the caller reads immediately.
--
-- The decisions themselves are in `shared/model.lua`, which touches no host at
-- all: the server hands it predicates and reads its verdicts. That is the split
-- `modules/target/shared/model.lua` uses and it is here for the same reason --
-- the rules are the half worth testing, and they are testable without a game.

local M = OPX.Modules.Declare{
	id = 'calls',
	side = 'both',
	fatal = false,
	-- The citizen id a contact row is filed under, and the name a card shows.
	-- Neither is readable without it, so this is a requirement and not a wish.
	requires = { 'character' },
	-- The eye carries every row this module has -- accept, decline, hang up,
	-- call, share a contact, add a third. Without it the calls still work over
	-- the contract and the commands, and nobody can reach them by looking at
	-- somebody. That is a diminished module, not a broken one.
	optional = { 'target', 'menu' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- The wire, named once so a typo is a nil index rather than a name nobody
--- raises. Server to client first, then client to server.
M.Event = {
	-- The whole of one player's call world: the live call if any, the invite
	-- waiting for them if any. Pushed on every change, never diffed -- the
	-- object is four fields and a list of three, and a diff would be more code
	-- than the thing it describes.
	STATE = OPX.Event(NET, 'calls', 'state'),

	-- Ask for the state again. Sent on start, on a world entry, and by the
	-- page's mount handshake, so a reloaded page is told the call it is on.
	READY = OPX.Event(NET, 'calls', 'ready'),

	-- The five verbs a client may ask for. Each carries the least it can: an
	-- invite names a target, an answer names the invite it answers.
	INVITE = OPX.Event(NET, 'calls', 'invite'),
	ACCEPT = OPX.Event(NET, 'calls', 'accept'),
	DECLINE = OPX.Event(NET, 'calls', 'decline'),
	-- Leaves the call; with no call, withdraws the invite still ringing out.
	HANG_UP = OPX.Event(NET, 'calls', 'hangup'),
	-- Withdraws the invite still ringing out and touches no call. ITS OWN VERB
	-- because the two used to share `HANG_UP`, and the server read "on a call"
	-- first: a player on a live call who had just asked a third person to join
	-- pressed X to take the invite back and ended their own call instead.
	WITHDRAW = OPX.Event(NET, 'calls', 'withdraw'),

	-- Client to server: delete the contact a row of the last list stands for.
	-- The row's reference is the server's own, minted with that list.
	FORGET = OPX.Event(NET, 'calls', 'forget'),

	-- The menu's list, asked for and answered. The owner wanted a third
	-- participant addable "par le menu ou par le ALT", and the ALT path needs
	-- somebody standing in front of you -- so the menu path needs a list of
	-- people who are not.
	--
	-- IT IS THE CALLER'S CONTACTS AND NOBODY ELSE, which is what makes contact
	-- sharing worth having rather than a write-only feature: the people you can
	-- ring from a menu are exactly the people who agreed to be reachable that
	-- way. The obvious alternative -- every connected player -- is an unbounded
	-- list, and it is also a presence and a position leak dressed as a feature.
	ASK_ROSTER = OPX.Event(NET, 'calls', 'roster'),
	ROSTER = OPX.Event(NET, 'calls', 'contacts'),

	-- Client-local: the state half to the hologram. One channel carrying a
	-- `kind`, the way `modules/downed/client/view.lua` explains at length; the
	-- only kind left is `holo`, since the overlay card that took `state` went.
	VIEW = OPX.Event(LOCAL, 'calls', 'view'),
}

--- The operation name a refusal is filed under, so a client waiting on one of
--- several requests can tell which `error.tooFast` is its own. `OPX.Refuse`
--- documents why this is not optional.
M.Operation = {
	INVITE = 'calls.invite',
	ANSWER = 'calls.answer',
	HANG_UP = 'calls.hangup',
	WITHDRAW = 'calls.withdraw',
	FORGET = 'calls.forget',
}
