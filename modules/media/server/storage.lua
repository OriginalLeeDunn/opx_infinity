--- Durable desk payments, hourly caps and purchased-scene history.
-- @author dop42
local M = OPX.Modules.Get('media')
local Storage, Result = OPX.Storage, OPX.Result
M.Storage = {}
local Store = M.Storage
Store.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_media_state (
    network_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_media_sales (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    op_id VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    network_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    desk_key VARCHAR(97) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    amount BIGINT NOT NULL,
    funded VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    sold_at DATETIME NOT NULL,
    KEY idx_opx77_media_seller (citizen_id, sold_at),
    KEY idx_opx77_media_network (network_key, funded, sold_at),
    KEY idx_opx77_media_desk (desk_key, id)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_media_scenes (
    op_id VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    scene_no SMALLINT UNSIGNED NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    PRIMARY KEY (op_id, scene_no),
    CONSTRAINT fk_opx77_media_scene_sale FOREIGN KEY (op_id) REFERENCES opx77_media_sales (op_id)
) ENGINE=InnoDB
]],
}

function Store.NewId() return Storage.Scalar('SELECT UUID()') end

--- A quote snapshot. Its revision and both caps are checked again under SQL locks.
function Store.State(citizenId, network, desk, seconds)
	local read = Storage.Single([[
SELECT
 (SELECT COALESCE(SUM(amount), 0) FROM opx77_media_sales
   WHERE citizen_id = @citizen AND sold_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3600 SECOND)) AS seller,
 (SELECT COALESCE(SUM(amount), 0) FROM opx77_media_sales
   WHERE network_key = @network AND funded = 'mint'
     AND sold_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3600 SECOND)) AS minted,
 (SELECT COALESCE(MAX(id), 0) FROM opx77_media_sales WHERE desk_key = @desk) AS revision
]], { citizen = citizenId, network = network, desk = desk })
	if not read.ok or type(read.value) ~= 'table' then return Result.Err('error.unavailable') end
	local scenes = Storage.Query([[
SELECT p.x, p.y, p.z, TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', s.sold_at) AS at
  FROM opx77_media_scenes p JOIN opx77_media_sales s ON s.op_id = p.op_id
 WHERE s.desk_key = @desk AND s.sold_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL @seconds SECOND)
 ORDER BY s.id DESC, p.scene_no LIMIT 10000
]], { desk = desk, seconds = seconds })
	if not scenes.ok or type(scenes.value) ~= 'table' or #scenes.value >= 10000 then return Result.Err('error.unavailable') end
	local rows = {}
	for _, scene in ipairs(scenes.value) do
		rows[#rows + 1] = { x = tonumber(scene.x) or 0, y = tonumber(scene.y) or 0,
			z = tonumber(scene.z) or 0, at = tonumber(scene.at) or 0 }
	end
	return Result.Ok({ seller = tonumber(read.value.seller) or 0, minted = tonumber(read.value.minted) or 0,
		revision = tonumber(read.value.revision) or 0, scenes = rows })
end

--- Sale/cap/scene effects are participants in the same item/wallet transaction.
-- sale={network,desk,total,funded,revision,sellerCap,mintCap,scenes={{x,y,z}}}.
function Store.SaleStatements(op, sale)
	local clauses = {
		'(SELECT COALESCE(SUM(amount), 0) FROM opx77_media_sales WHERE citizen_id = ? '
			.. 'AND sold_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3600 SECOND) FOR UPDATE) <= ?',
		'(SELECT COALESCE(MAX(id), 0) FROM opx77_media_sales WHERE desk_key = ? FOR UPDATE) = ?',
	}
	local values = { op.citizenId, sale.sellerCap - sale.total, sale.desk, sale.revision }
	if sale.funded == 'mint' then
		clauses[#clauses + 1] = '(SELECT COALESCE(SUM(amount), 0) FROM opx77_media_sales '
			.. "WHERE network_key = ? AND funded = 'mint' AND sold_at > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 3600 SECOND) FOR UPDATE) <= ?"
		values[#values + 1], values[#values + 2] = sale.network, sale.mintCap - sale.total
	end
	local statements = {
		{ query = 'INSERT INTO opx77_media_sales (op_id, citizen_id, network_key, desk_key, amount, funded, sold_at) '
			.. 'SELECT op_id, citizen_id, ?, ?, ?, ?, UTC_TIMESTAMP() FROM opx77_money_ledger WHERE op_id = ? AND attempt_token = ?',
			values = { sale.network, sale.desk, sale.total, sale.funded, op.id, op.attempt } },
	}
	-- Four values per scene plus the two receipt bindings fit the bridge's 64.
	for first = 1, #sale.scenes, 15 do
		local selects, params = {}, {}
		for index = first, math.min(first + 14, #sale.scenes) do
			local scene = sale.scenes[index]
			selects[#selects + 1] = 'SELECT ? AS scene_no, ? AS x, ? AS y, ? AS z'
			for _, value in ipairs({ index, scene.x, scene.y, scene.z }) do params[#params + 1] = value end
		end
		params[#params + 1], params[#params + 2] = op.id, op.attempt
		statements[#statements + 1] = {
			query = 'INSERT INTO opx77_media_scenes (op_id, scene_no, x, y, z) SELECT l.op_id, r.scene_no, r.x, r.y, r.z FROM ('
				.. table.concat(selects, ' UNION ALL ') .. ') r JOIN opx77_money_ledger l ON l.op_id = ? AND l.attempt_token = ?',
			values = params,
		}
	end
	-- This nonfinancial upsert takes the network X-lock before wallet/cap reads,
	-- including the first sale and READ COMMITTED isolation (no gap-lock reliance).
	local before = { { query = 'INSERT INTO opx77_media_state (network_key) VALUES (?) '
		.. 'ON DUPLICATE KEY UPDATE network_key = VALUES(network_key)', values = { sale.network } } }
	return statements, { query = table.concat(clauses, ' AND '), values = values, error = 'error.unavailable' }, before
end
