--- How long a call rings, how many may be on it, and what it sounds like.
-- @author dop42
--
-- Shared, like the garages and teleports configs above it and for the same
-- reason: the client half reads the sound names, the participant ceiling and
-- the refusal windows here, and the server re-derives every bound the client
-- thinks it knows. Nothing in this file is a decision -- every one of these
-- values is checked again on the server before it changes anything.

OPX.Config.MODULES.calls = {
	enabled = true,

	-- People on one call. Bounded at three by `Model.MAX_PARTICIPANTS` whatever
	-- is written here: `order` crosses to every participant's screen as a
	-- fixed-size row, and the owner asked for a third, not for a conference.
	MAX_PARTICIPANTS = 3,

	-- Seconds an unanswered invite rings before it gives up. It holds the
	-- caller's one outgoing slot and the target's one incoming slot for the
	-- whole of it, so this is also how long a call nobody picks up locks both
	-- of them out of placing another.
	INVITE_TTL_S = 30,

	-- Floor between two requests of one kind from one player, in milliseconds.
	-- A call is a card on somebody else's screen, so the spam this stops is
	-- aimed at a person rather than at the server.
	REQUEST_MS = 1500,

	-- Metres between two bodies for a CONTACT hand-over, and the only distance
	-- rule in the module. A call reaches across the city -- that is the
	-- feature -- but handing somebody your number is something you do standing
	-- in front of them, and it is the one action the eye offers that a client
	-- could otherwise claim from anywhere.
	CONTACT_RANGE = 6.0,

	-- Contact rows one character may keep. A bounded list, because it is
	-- written to the character's metadata blob and that blob is read on every
	-- load.
	MAX_CONTACTS = 64,

	-- The blue eye-glow lease, in milliseconds.
	--
	-- BOUNDED AND RENEWED, NEVER HELD OPEN. `Open77.players.setHoloCallEyes`
	-- takes `durationMs = 0` to mean "until this resource releases it", and
	-- that is the shape `modules/animations/client/walk.lua` has a whole header
	-- about: a lease is not tied to the thing that justified it, so if a call
	-- ends down a path nobody released on, the player walks around with lit
	-- eyes for the rest of the session with no idea why. A lease that expires
	-- on its own means the worst case is LEASE_MS of glow rather than a
	-- session of it, and the renewal below is what makes a live call keep it.
	EYES = {
		LEASE_MS = 30000,
		RENEW_MS = 10000,
	},

	-- Milliseconds between sweeps: expiring invites, renewing leases, and
	-- checking that everybody on a call is still there.
	SCAN_MS = 2000,

	-- ── the sound ────────────────────────────────────────────────────────────
	--
	-- THE GAME'S OWN, PLAYED BY NAME, WITH NOTHING SHIPPED. These are Wwise
	-- event names out of Cyberpunk's own `ui_phone_01` bank, read from the
	-- devkit's sfx catalogue for game build 2.31 -- not invented, and not an
	-- audio file copied out of the game and redistributed with this resource.
	-- `Open77.sfx.play2d(event)` posts them through `gameGameAudioSystem::Play`
	-- with no entity, which is the same door the vanilla frontend uses for its
	-- own menu sounds. So the incoming call sounds exactly like an incoming
	-- call because it IS the incoming call sound.
	--
	-- The platform refuses a name outside its curated table with
	-- `invalid_sfx_event` rather than forwarding it, so a typo here is a
	-- refusal the client half notes once and not a silent no-op. Every name is
	-- carried as `seed_requires_2.31_runtime_validation` in the catalogue --
	-- the devkit has read them out of the bank but has not played them on this
	-- build -- which is the other reason the client treats a refusal as a
	-- missing sound rather than as a fault.
	--
	-- An empty string switches one off, the way `config/admin.lua`'s noclip
	-- SOUND does. An operator who wants their own ringtone instead wants
	-- `Open77.sound.play` and a file in `web/audio/`, which is a different
	-- door and is not wired here.
	SOUND = {
		-- The ring, on the screen being called.
		INCOMING = 'ui_phone_incoming_call',
		-- Silences the ring: answered, refused, expired or hung up.
		INCOMING_STOP = 'ui_phone_incoming_call_stop',
		ACCEPTED = 'ui_phone_incoming_call_positive',
		DECLINED = 'ui_phone_incoming_call_negative',

		-- The dial tone, on the screen that placed the call.
		OUTGOING = 'ui_phone_initiation_call',
		OUTGOING_STOP = 'ui_phone_initiation_call_stop',

		-- The line closing, on every screen that was on it.
		HANG_UP = 'ui_phone_off',
	},

	-- Milliseconds between two re-arms of the ring, so an incoming call rings
	-- for as long as the invite stands rather than once. `ui_phone_incoming_call`
	-- is a one-shot: there is no loop to start and no handle to stop, which is
	-- why `INCOMING_STOP` exists as a separate event and why this is a clock
	-- rather than a flag.
	RING_EVERY_MS = 3500,

	-- ── THE KEY, AND THE INTERACTION MODEL IT REPLACED ───────────────────────
	--
	-- THE OWNER: "fait en sorte que cela passe pas par alt ce serais en gros
	-- fait une touche qui ouvre un menu style halogram tous se passe desus call
	-- resus contact etc plus de alt", and then: "le halo prend vrais le devant
	-- de l'ecran", "en plein centre".
	--
	-- This feature was built on the target eye. Eight rows: answer, refuse, hang
	-- up, call this person, add them, share a contact, open the contacts, bring
	-- the card back. Every one of them is gone, and the whole of the interaction
	-- is one screen this key opens.
	--
	-- WHY THE EYE WAS THE WRONG PLACE, now that it has been used: ALT needs a
	-- body under the crosshair, and a holocall is the thing you reach for when
	-- the person is NOT in front of you. Answering a call meant pointing at
	-- yourself first. The eye was the mechanism at hand rather than the one the
	-- feature wanted.
	--
	-- `H` for holo. Free on this build -- `E` is contextual, `I` the bag, `T`
	-- chat, `Y` the hotbar peek, `X` stops an emote, `F1` the menu, `F3` the
	-- animation picker, `F4` the skill tree, `F9` the staff menu (F10 is free
	-- since the Dev screen went) -- and `false`
	-- switches the key off entirely for a server that would rather bind it
	-- elsewhere.
	KEY = { ID = 'opx.calls.holo', NAME = 'calls.key.holo', DEFAULT = 'H' },

	-- ── ANSWERING WITHOUT OPENING ANYTHING ───────────────────────────────────
	--
	-- THE OWNER: "tu vas juste pop l'animation pas le menu est dans la sphere tu
	-- vas ajouter les gens qui appel ou presnter un incoming call puis avec les
	-- prompt afficher y pour repondre x pour reffuser".
	--
	-- A call arriving must not open a screen. It pops the projection, puts the
	-- caller inside it, and says which two keys answer it -- so a player who is
	-- driving, shooting or reading something else is told, and decides, without
	-- anything taking the mouse or the keyboard from them.
	--
	-- THESE TWO KEYS ARE ALREADY SPOKEN FOR, AND THAT IS THE OWNER'S CALL RATHER
	-- THAN AN OVERSIGHT. `Y` is the hotbar peek (`config/inventory.lua`) and `X`
	-- stops an emote (`config/animations.lua`). The platform lets two actions
	-- share a physical key and fires both, so outside a ringing call these
	-- behave exactly as they did -- the handlers here do nothing at all unless
	-- there is a call to answer. While one IS ringing, pressing Y also peeks the
	-- hotbar for a moment. X is CONTESTED (`KEY_PRIORITY` in
	-- `config/client.lua`): a ringing call takes the press from an emote and a
	-- carried crate, a cancelable bar takes it from the call, and hanging up a
	-- call that is merely going on comes after all of them. Move whichever
	-- bothers you; all three are config.
	-- WHERE THE PROJECTION SITS. The owner moved this by hand three times --
	-- centre, then bottom, then flush to the edge -- and every one of those was a
	-- CSS edit because the value was not a setting. It is one now, and it speaks
	-- the vocabulary in `lib/shared/anchors.lua`: the same nine names everywhere
	-- they appear, rather than the three different sets eight config blocks were
	-- quietly accepting behind one word.
	--
	-- A name that is not one of the nine is REFUSED AND NAMED in the journal, not
	-- swallowed: a typo here is a screen in a corner nobody chose, and that is the
	-- one fault a silent fallback makes impossible to find.
	ANCHOR = 'bottom-center',

	ANSWER_KEY = { ID = 'opx.calls.answer', NAME = 'calls.key.answer', DEFAULT = 'Y' },
	DECLINE_KEY = { ID = 'opx.calls.decline', NAME = 'calls.key.decline', DEFAULT = 'X' },
}
