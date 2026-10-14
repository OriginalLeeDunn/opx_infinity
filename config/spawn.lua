--- Where a player may choose to start, and how long they have to say so.
-- @author dop42
--
-- A character is born with no position: the row exists before its player has
-- stood anywhere, so `spawn` is the one module that decides where a brand new
-- character lands.
--
-- WHICH WORLD ENTERS ARE ASKED IS THE OPERATOR'S CALL, and it is `OFFER_POLICY`
-- below. Whatever that says, the answer to a choice nobody makes is the same one:
-- a player who picks a spot is placed there, and one who picks nothing -- or
-- never opens the menu, or lets the window run out -- is placed by `character`
-- with no explicit target, which resolves to the row's own position. Only a
-- character whose row holds nowhere reaches `character.DEFAULT_SPAWN`.
--
-- The module reads this as `M.Settings`.
--
-- THE COORDINATES ARE NOT INVENTED. Every entry below is copied verbatim --
-- position and heading both -- from `resources/gamemodes/freeroam/shared/config.lua`
-- in open77-base, whose `locations` table is documented there as "repository
-- captures ... safe landing spots" from the platform's own entity and respawn
-- captures. A made-up coordinate is a player who lands inside geometry, falls
-- through the world, or arrives dead, so nothing here is guessed: to add a spot,
-- stand on it in game, read the position, and copy the numbers.
--
-- `heading` is degrees, and 0.0 is a legitimate facing rather than "unset": it is
-- north. The heading is what the kill-then-respawn transaction uses, so a spot
-- without a considered one arrives facing whatever direction that number means.

OPX.Config.MODULES.spawn = {
	enabled = true,

	-- WHICH WORLD ENTERS ARE OFFERED THE MENU. Three values, and no fourth:
	--
	--   'first'   only a character that has never stood anywhere. The row's
	--             position is what says so -- it is NULL until the first save
	--             after the first placement -- so this is "ask once per
	--             character, ever", and a returning player resumes in silence.
	--   'always'  every world enter, a returning character included. Choosing is
	--             the exception and resuming is still the default: a returning
	--             player who picks nothing is placed back where their row says.
	--   'never'   nobody is ever asked. The character starts where it already is,
	--             and only a row holding nowhere reaches `character.DEFAULT_SPAWN`.
	--
	-- WHY THIS IS A SETTING AND NOT A GUESS. The two defensible answers are
	-- opposite and both are somebody's server: a roleplay server asks once, at
	-- character creation, and never interrupts a returning player again; a
	-- freeroam server asks every time because starting somewhere new is the point
	-- of the session. This module shipped hard-wired to the second, which cost the
	-- first an unskippable modal on every join.
	--
	-- 'never' IS NOT THE SAME AS `enabled = false`, and the difference is worth
	-- the two words: switched off, the module does not load, its catalogue is not
	-- read and its locales are not registered. Set to 'never' it is loaded and
	-- silent -- the catalogue is still validated at start, so a typo in a
	-- coordinate is still named in the journal on a server that intends to turn
	-- the menu on next week.
	--
	-- UNDER 'never' NO CLOCK IS ARMED AT ALL. Neither TIMEOUT_SECONDS nor
	-- HOLD_MAX_SECONDS below runs, because nothing is held: the module declines
	-- the placement outright and `character` performs it in the same tick. A
	-- character held by a deadline for a menu that will never be drawn would be a
	-- player standing in the pre-game position until the hold ran out.
	--
	-- An unknown value is REFUSED WITH A LINE IN THE JOURNAL and falls back to
	-- 'always', which is what this module did before the setting existed. It is
	-- never guessed at: 'firstspawn', 'once' and true are each a typo, and a typo
	-- that silently turned the menu off would look exactly like the module being
	-- broken.
	-- THE OWNER: "active le config pour pas que cela me propose de choisir mon
	-- spwan a chaque connection cela me remet au lieu de dernier connexion".
	-- That is this setting and nothing else -- 'first' asks once, at character
	-- creation, and a returning character resumes where its row says it was
	-- standing when it left. The paragraph above calls this the roleplay answer
	-- and it is the one this server wants.
	OFFER_POLICY = 'first',

	-- How long a player has to pick before the server places them at
	-- `character.DEFAULT_SPAWN` and takes the menu down. This is the ONLY thing
	-- that ends a spawn choice the player never makes: without it a disconnected
	-- client or a surface that never draws would leave a character standing in
	-- the pre-game position, unnamed and unplaceable, for the session.
	--
	-- Long enough to read eleven cards, short enough that a player who has walked
	-- away is not held. The page draws its own countdown from this number, and
	-- that countdown is display only -- the server's own clock is the one that
	-- ends the choice.
	--
	-- Five seconds is the floor, and it is enforced rather than suggested: a zero
	-- from a typo would end the choice in the tick it was offered. So an operator
	-- may shorten this, but not past five, and not to nothing.
	--
	-- THIS CLOCK STARTS WHEN THE MENU IS ON SCREEN, not when the offer is queued.
	-- The two are not the same moment and used to differ by tens of seconds: a
	-- brand new character is asked for a NAME at the same instant the server
	-- offers the spawn, so the menu stands aside behind that form. Measured on a
	-- live server, the offer was queued at 16:09:33 and the name was answered at
	-- 16:10:14 -- a forty-five second window that left four seconds of menu, and
	-- none at all if the form had run a little longer. The server starts this
	-- clock when the client reports the menu up.
	TIMEOUT_SECONDS = 45,

	-- How long an offer NOBODY OPENS may hold a character unplaced, in seconds.
	--
	-- A bound on the runtime, not on the player: waiting on someone who is
	-- choosing is the normal case and lasts as long as TIMEOUT_SECONDS says. This
	-- is the other case -- a client that never draws the menu at all, which would
	-- otherwise leave a character standing in the pre-game position for the whole
	-- session, with no name and no way to be placed. Sixty seconds is the floor.
	--
	-- IT IS ALSO THE BOUND ON EVERYTHING AHEAD OF THE MENU, and that is the part
	-- worth reading before shortening it. The menu is the LAST of three questions
	-- a new character answers -- a name, then an outfit, then this -- and it
	-- stands aside for the whole of the first two (see WAIT_FOR_ENTRY below, and
	-- WARDROBE.OFFER_POLICY in config/appearance.lua). All of that happens inside
	-- this hold, because the player's own window has not started yet. A number
	-- below the time somebody plausibly spends naming a character and dressing it
	-- is a number that settles their spawn from the row while they are still in
	-- the fitting room, with no menu ever drawn and nothing on screen to say why.
	HOLD_MAX_SECONDS = 300,

	-- Rate limit on the choice itself, in milliseconds. The menu is one shot; a
	-- client that sends twice is a stutter or a modified client, and either way
	-- it gets the one it asked for first.
	CHOOSE_COOLDOWN_MS = 1000,

	-- Whether the menu waits for the entry module to stop asking its own
	-- questions before it opens.
	--
	-- A brand new character is asked THREE things at once -- the name form, which
	-- lives in the world; the fitting room, which the appearance module offers on
	-- its own policy; and this, which is decided at the same moment the platform
	-- announces a living body. Drawn together they are three modals fighting for
	-- one keyboard, so with this true the menu waits for entry to report itself
	-- idle -- and entry reports the join busy for the fitting room too, which is
	-- why there is one setting here and not two. Entry also reports a name that
	-- is owed from the moment the character loads, before its form can open
	-- (entry's NAME_CLAIM_SECONDS), and never opens that form over this menu
	-- once it is up. The wait is bounded by
	-- HOLD_MAX_SECONDS above: a question nobody answers costs the player the
	-- choice, not the session.
	WAIT_FOR_ENTRY = true,

	-- Whether the menu waits until the player can see the screen.
	--
	-- The menu's page takes the open as soon as its surface is up, which is
	-- before anybody can see it. At join, the server's loading screen covers every
	-- surface until the platform has reset the body. During play, a native load
	-- (a respawn, a teleport) covers it while the load runs. In the bot lab the
	-- offer came ten seconds before the loading screen came down, so the window
	-- started with ten of its forty-five seconds hidden. With this true, the menu
	-- waits while a native load is up and, at join, until the platform has
	-- finished resetting the body. The server's clock starts when the menu is
	-- really on screen. The wait is reported to the server like entry's, inside
	-- HOLD_MAX_SECONDS.
	WAIT_FOR_SCREEN = true,

	-- The longest one offer waits for the screen, in seconds: 5 at least, 120 at
	-- most. If the screen still has not cleared by then, the menu opens anyway,
	-- with a line in the client's log. A loading screen that never says it is
	-- over then costs the player this wait, never the choice.
	SCREEN_WAIT_SECONDS = 60,

	-- The places a new character may start.
	--
	-- `id` is what the wire carries and what the server looks the spot up by, so
	-- an id is permanent: renaming one refuses every client that still knows the
	-- old name. `label` and `district` are drawn; `district` is the hint line
	-- under the label, which is why it is the district and not the coordinates.
	LOCATIONS = {
		{ id = 'stoop',      label = 'King Stoop forecourt',   district = 'Watson',      x = -410.22,  y = 722.73,   z = 115.0, heading = 147.0 },
		{ id = 'northside',  label = 'North promenade',        district = 'Watson',      x = -469.47,  y = 930.99,   z = 56.45, heading = -68.0 },
		{ id = 'junction',   label = 'Lower Watson junction',  district = 'Watson',      x = -644.91,  y = 1019.37,  z = 36.56, heading = 75.5 },
		{ id = 'underpass',  label = 'Lower Watson underpass', district = 'Watson',      x = -701.49,  y = 1033.97,  z = 35.71, heading = -104.5 },
		{ id = 'city',       label = 'City west',              district = 'City Center', x = -667.14,  y = -382.61,  z = 9.16,  heading = 0.0 },
		{ id = 'lab',        label = 'Open77 laboratory',      district = 'East',        x = 1669.75,  y = -739.12,  z = 49.86, heading = 0.0 },
		{ id = 'dealer',     label = 'Vehicle dealership',     district = 'Westbrook',   x = -1442.2,  y = 127.4,    z = 18.0,  heading = 0.0 },
		{ id = 'racegrid',   label = 'Westbrook race grid',    district = 'Westbrook',   x = -1450.2,  y = 119.9,    z = 14.8,  heading = 200.0 },
		{ id = 'heights',    label = 'Northwest heights',      district = 'North Oak',   x = -1441.0,  y = 1269.0,   z = 123.0, heading = 180.0 },
		{ id = 'arena',      label = 'Freeroam arena',         district = 'Badlands',    x = 381.358826, y = -2401.794189, z = 181.988541, heading = 0.0 },
		{ id = 'coast',      label = 'Southwest coast',        district = 'Badlands',    x = -1716.38, y = -2421.28, z = 62.59, heading = 0.0 },
	},
}
