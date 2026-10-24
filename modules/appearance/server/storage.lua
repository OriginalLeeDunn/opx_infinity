--- Every SQL statement this module runs, and the one table it owns.
-- @author dop42
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: validation and ownership are the
-- caller's. Every statement yields and answers a `Result`, so every one of them
-- has to be reached from a `CreateThread`.
--
-- Statements bind named parameters (`@citizen`), never `?`: the bridge rewrites
-- `?` by walking the query text. No comment may appear inside a SQL string for
-- the same reason.
--
-- The face is NOT in this module's table. It is one nullable JSON column on the
-- character row, so that it travels with the character and disappears with it,
-- and so that a face survives exactly as long as the character it belongs to.
-- This module owns what goes in that column; the character module owns the row.

local M = OPX.Modules.Get('appearance')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

--- The create statement `Init` contributes to the schema.
-- Taken verbatim from the core it was ported out of, foreign key included: a
-- clothing record for a character that no longer exists is not a record, and the
-- cascade is what keeps a deleted character from leaving one behind.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_character_clothing (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    clothing JSON NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_opx77_character_clothing_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],
}

--- Writes a character's face column at once; nil clears it.
-- @author dop42
-- @param citizenId CitizenId
-- @param appearance table|nil
-- @return Result
function M.Storage.SaveAppearance(citizenId, appearance)
	return Storage.Execute([[
UPDATE opx77_characters
   SET appearance = NULLIF(@appearance, '')
 WHERE citizen_id = @citizen AND deleted_at IS NULL
  ]], {
		citizen = citizenId,
		-- The bridge DROPS a nil parameter rather than binding NULL, so absence
		-- travels as '' and NULLIF turns it back. Encoded JSON is never ''.
		appearance = Storage.Nullable(appearance),
	})
end

--- Reads the stored face of a character nobody has loaded.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result the snapshot, or nil for a character that has none
function M.Storage.FetchAppearance(citizenId)
	local row = Storage.Single([[
SELECT appearance FROM opx77_characters
 WHERE citizen_id = @citizen AND deleted_at IS NULL
 LIMIT 1
  ]], { citizen = citizenId })
	if not row.ok then return row end
	if not row.value then return Result.Err('character.notFound', citizenId) end
	return Result.Ok(Storage.Decode(row.value.appearance, nil))
end

--- Reads a character's stored clothing document, or nil for none.
-- A column that will not decode is a failure and not an absence: answering nil
-- would read as 'nothing stored yet', and the next save would overwrite a record
-- nobody was ever shown.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.FetchClothing(citizenId)
	local row = Storage.Single([[
SELECT clothing FROM opx77_character_clothing
 WHERE citizen_id = @citizen
 LIMIT 1
  ]], { citizen = citizenId })
	if not row.ok then return row end
	if not row.value then return Result.Ok(nil) end

	local decoded = Storage.Decode(row.value.clothing, nil)
	if decoded == nil then return Result.Err('clothing.unreadable', citizenId) end
	return Result.Ok(decoded)
end

--- Writes a character's encoded clothing record at once.
-- @author dop42
-- @param citizenId CitizenId
-- @param encoded string a validated record, already encoded
-- @return Result
function M.Storage.SaveClothing(citizenId, encoded)
	return Storage.Execute([[
INSERT INTO opx77_character_clothing (citizen_id, clothing)
VALUES (@citizen, @clothing)
ON DUPLICATE KEY UPDATE clothing = VALUES(clothing)
  ]], { citizen = citizenId, clothing = encoded })
end

--- Removes everything this module stores for a character that has been deleted.
-- @author dop42
--
-- THE FOREIGN KEY DOES NOT DO THIS, and the row above it says why it looks as
-- though it should: `opx77_character_clothing.citizen_id` really does carry
-- `ON DELETE CASCADE` onto `opx77_characters`. But a character delete is a SOFT
-- delete -- `deleted_at` is stamped and the row stays, so the slot is freed
-- without losing the history -- and no cascade fires for an UPDATE. So every
-- cascade in this schema is correct and none of them has ever run on a player
-- deleting a character.
--
-- The face is not here and needs nothing: it is a column on the character row
-- itself, so it goes when that row does.
-- @param citizenId CitizenId
-- @return Result
function M.Storage.PurgeCharacter(citizenId)
	return Storage.Execute('DELETE FROM opx77_character_clothing WHERE citizen_id = @citizen',
		{ citizen = citizenId })
end

--- A paid outfit and its wallet debit share the same receipt attempt.
function M.Storage.ClothingStatements(op, encoded)
	return { { query = 'INSERT INTO opx77_character_clothing (citizen_id, clothing) ' ..
		'SELECT ?, ? FROM opx77_money_ledger WHERE op_id = ? AND attempt_token = ? ' ..
		'ON DUPLICATE KEY UPDATE clothing = VALUES(clothing)',
		values = { op.citizenId, encoded, op.id, op.attempt } } }
end
