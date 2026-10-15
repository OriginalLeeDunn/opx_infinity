--- Media: N54 News, WNS and the screamsheet -- reporters in the field, the
--- editor desk that buys their work, and the breaking news every screen shows.
-- @author dop42
--
-- THE LOOP, AS NIGHT CITY TELLS IT. A journalist holds the `reporter` job --
-- Stringer, Reporter, Anchor, Editor-in-chief -- and works for one NEWSROOM
-- (a line on their character). In the field they shoot PHOTOS with a press
-- camera and file STORIES; both are items carrying a byline, a time and, for a
-- photo, a place and the crowd in frame. The newsroom's EDITOR DESK buys them,
-- paid from the newsroom's treasury through the `accounts` contract when the
-- business module runs, minted under an hourly cap when it does not. Anchors
-- and Editors BREAK NEWS: a headline and a line of text on every player's
-- screen, drawn by the very overlay and stingers the staff announcement uses.
-- Anybody can phone the TIPS LINE (`/tip`), anonymously, and every reporter on
-- duty hears it.
--
-- EVERYTHING IS THE SERVER'S. A client names a desk, a headline, a story; the
-- job, the grade, the newsroom, the position, the bag, the clock and the price
-- are read here. A photo is taken by a server-timed `progress` bar and its
-- facts -- where, when, who was near -- are the server's reads, never the
-- client's word. A real screenshot is OPTIONAL: Open77 delivers one only to an
-- external URL (`players.requestScreenshot`), so without `PHOTO.UPLOAD_URL` a
-- photo is the record of a photo being taken, which is what the desk prices.
--
-- `character` and `inventory` are required: without the first nobody is paid
-- or gated, without the second there is no camera, photo or story.

local M = OPX.Modules.Declare{
	id = 'media',
	side = 'both',
	fatal = false,
	requires = { 'character', 'inventory' },
	optional = { 'target', 'progress', 'form', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- ONE DOOR for every request, `{ verb, ... }`, each verb re-validated:
	--   `{ verb = 'breaking', headline, text }`: break news for the sender's newsroom;
	--   `{ verb = 'story', headline, body }`: file a story;
	--   `{ verb = 'sell', network, desk }`: sell one's own photos and stories to a desk.
	REQUEST = OPX.Event(NET, 'media', 'request'),

	-- Server to client: a break to draw, `{ network, tag, label, headline,
	-- text, durationMs }`.
	BROADCAST = OPX.Event(NET, 'media', 'broadcast'),
	-- Server to client: an anonymous tip, `{ id, text }`.
	TIP = OPX.Event(NET, 'media', 'tip'),
	-- Server to client: open a form, `{ kind = 'breaking'|'story', label,
	-- limits = { ... } }`.
	FORM = OPX.Event(NET, 'media', 'form'),
	-- Server to client: somebody shows a press pass, `{ name, network, grade,
	-- status = 'valid'|'revoked'|'unverified' }`.
	PASS = OPX.Event(NET, 'media', 'pass'),

	-- The public SERVER bus, for other resources.
	-- `(player, { network, headline, text })`
	ON_BROADCAST = OPX.Event(LOCAL, 'media', 'broadcast'),
	-- `(player, { network, desk, photos, stories, total, source = 'accounts'|'mint' })`
	ON_SOLD = OPX.Event(LOCAL, 'media', 'sold'),
	-- `(player, { serial, network, x, y, z, crowd, uploaded })`
	ON_PHOTO = OPX.Event(LOCAL, 'media', 'photo'),
	-- `(nil, { id, receivers })` -- never the sender.
	ON_TIP = OPX.Event(LOCAL, 'media', 'tip'),
}

--- The player commands, by name. Each one's host gate is `command.<name>`.
M.Command = {
	BREAKING = 'breaking',
	STORY = 'story',
	TIP = 'tip',
	TIPS = 'tips',
	NEWS = 'news',
	KIT = 'presskit',
	NETWORK = 'pressnet',
	-- Staff.
	ASSIGN = 'opx.media.assign',
	DESKS = 'opx.media.desks',
	CAPTURE = 'opx.media.capture',
}
