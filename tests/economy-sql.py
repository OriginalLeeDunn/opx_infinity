#!/usr/bin/env python3
"""Run actual Lua storage plans against an explicitly isolated MariaDB database.

OPX_LUA=lua OPX_TEST_DB_SOCKET=/tmp/test.sock python3 tests/economy-sql.py
Requires PyMySQL for test tooling only. No production configuration is read.
"""
import json
import os
from pathlib import Path
import subprocess
import uuid
from concurrent.futures import ThreadPoolExecutor
import pymysql

ROOT = Path(__file__).resolve().parents[1]
if not os.environ.get('OPX_TEST_DB_SOCKET') and not os.environ.get('OPX_TEST_DB_PORT'):
  raise SystemExit('Set OPX_TEST_DB_SOCKET or OPX_TEST_DB_PORT for an isolated test server.')
plans = json.loads(subprocess.check_output([os.environ.get('OPX_LUA', 'lua'), 'tests/economy-sql-plans.lua'], cwd=ROOT))
settings = dict(user=os.environ.get('OPX_TEST_DB_USER', 'root'),
                password=os.environ.get('OPX_TEST_DB_PASSWORD', ''), autocommit=True,
                charset='utf8mb4')
if os.environ.get('OPX_TEST_DB_SOCKET'):
  settings['unix_socket'] = os.environ['OPX_TEST_DB_SOCKET']
else:
  settings.update(host='127.0.0.1', port=int(os.environ['OPX_TEST_DB_PORT']))
database = 'opx_test_economy_' + uuid.uuid4().hex[:10]
admin = pymysql.connect(**settings)
with admin.cursor() as cursor:
  cursor.execute('CREATE DATABASE ' + database)
settings['database'] = database
connection = pymysql.connect(**settings)
with connection.cursor() as cursor:
  for ddl in plans['schema']:
    cursor.execute(ddl)
  # Exercise additive definitions against legacy table shapes, not just fresh
  # CREATE statements. This database was created above solely for this test.
  for column in plans['columns']:
    cursor.execute('SHOW COLUMNS FROM ' + column['TABLE'] + ' LIKE %s', (column['COLUMN'],))
    if cursor.fetchone():
      cursor.execute('ALTER TABLE ' + column['TABLE'] + ' DROP COLUMN ' + column['COLUMN'])
  for column in plans['columns']:
    cursor.execute('ALTER TABLE ' + column['TABLE'] + ' ADD COLUMN ' + column['COLUMN'] + ' ' + column['DEFINITION'])
  # Existing phase records retain version zero: migrations cannot invent proof.
  for table, fields, values in (
      ('opx77_invoice_ledger', 'op_id,invoice_id,phase,amount,state', "'legacy',1,'charge',10,'reserved'"),
      ('opx77_contract_ledger', 'op_id,contract_id,phase,amount,state', "'legacy',1,'escrow',10,'reserved'")):
    cursor.execute('INSERT INTO ' + table + '(' + fields + ') VALUES(' + values + ')')
    cursor.execute('SELECT durable_version FROM ' + table + " WHERE op_id='legacy'")
    assert cursor.fetchone()[0] == 0
    cursor.execute('DELETE FROM ' + table)



def reset(case):
  with connection.cursor() as cursor:
    cursor.execute('DELETE FROM opx77_underworld_ledger')
    cursor.execute('DELETE FROM opx77_underworld_registers')
    cursor.execute('DELETE FROM opx77_underworld_batches')
    cursor.execute('DELETE FROM opx77_dealership_payouts')
    cursor.execute('DELETE FROM opx77_vehicles')
    cursor.execute('DELETE FROM opx77_character_clothing')
    cursor.execute('DELETE FROM opx77_crafting_orders')
    cursor.execute('DELETE FROM opx77_inventory_items')
    cursor.execute('DELETE FROM opx77_inventories')
    cursor.execute('DELETE FROM opx77_money_ledger')
    cursor.execute('DELETE FROM opx77_company_ledger')
    cursor.execute('DELETE FROM opx77_company_accounts')
    cursor.execute('DELETE FROM opx77_characters')
    cursor.execute('DELETE FROM opx77_users')
    cursor.execute("INSERT INTO opx77_users(user_id) VALUES('integration-user')")
    cursor.execute("INSERT INTO opx77_characters(citizen_id,user_id,char_info,money,job,gang,metadata) VALUES('ECONTEST','integration-user','{}',%s,'{}','{}','{}')",
                   (json.dumps({'EDDIES': case['balance']}),))
    cursor.execute("INSERT INTO opx77_inventories(id,kind,owner,citizen_id,slots,max_weight) VALUES(1,'character','ECONTEST','ECONTEST',50,100000)")
    cursor.execute("INSERT INTO opx77_inventory_items(inventory_id,slot,name,quantity,metadata) VALUES(1,1,'weapon_test',1,'{\"ammo\":9}')")
    cursor.execute("INSERT INTO opx77_company_accounts(kind,group_key,balance) VALUES('job','test',%s)", (case.get('company', 0),))
    if case['notes']:
      cursor.execute("INSERT INTO opx77_inventory_items(inventory_id,slot,name,quantity) VALUES(1,2,'eddies',%s)", (case['notes'],))

    if case.get('underworld') == 'batch':
      cursor.execute("INSERT INTO opx77_inventory_items(inventory_id,slot,name,quantity) VALUES(1,2,'dirty_eddies',100)")
    if case.get('underworld') == 'collect':
      cursor.execute("INSERT INTO opx77_underworld_batches(id,citizen_id,front_id,dirty,clean,payout,deposited_at,ready_at,durable_version) VALUES(1,'ECONTEST','front',100,80,'EDDIES',UTC_TIMESTAMP(),DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 SECOND),1)")
    if case.get('peer') is not None:
      cursor.execute("INSERT INTO opx77_characters(citizen_id,user_id,char_info,money,job,gang,metadata) VALUES('SELLTEST','integration-user','{}',%s,'{}','{}','{}')", (json.dumps({'EDDIES': case['peer']}),))
      cursor.execute("INSERT INTO opx77_inventories(id,kind,owner,citizen_id,slots,max_weight) VALUES(2,'character','SELLTEST','SELLTEST',50,100000)")
      cursor.execute("INSERT INTO opx77_inventory_items(inventory_id,slot,name,quantity) VALUES(2,1,'water',3)")
    if case.get('vehicle') == 'full':
      cursor.execute("INSERT INTO opx77_vehicles(plate,citizen_id,record,garage,metadata) VALUES('EXISTING','ECONTEST','Vehicle.test','test','{}')")
    if case.get('multi'):
      cursor.execute("INSERT INTO opx77_inventories(id,kind,owner,slots,max_weight) VALUES(2,'trunk','test-plate',50,100000)")
      cursor.execute("INSERT INTO opx77_inventory_items(inventory_id,slot,name,quantity) VALUES(1,2,'water',2),(2,1,'water',3)")
    if case.get('craft') in ('full', 'collect'):
      cursor.execute("INSERT INTO opx77_crafting_orders(id,citizen_id,bench,recipe,ready_at,token) VALUES(1,'ECONTEST','bench','rounds',DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 SECOND),'old-order')")


def state():
  with connection.cursor() as cursor:
    cursor.execute("SELECT JSON_VALUE(money,'$.EDDIES') FROM opx77_characters WHERE citizen_id='ECONTEST'")
    balance = int(cursor.fetchone()[0])
    cursor.execute("SELECT COALESCE(SUM(quantity),0) FROM opx77_inventory_items WHERE name='eddies'")
    notes = int(cursor.fetchone()[0])
    cursor.execute('SELECT COUNT(*) FROM opx77_money_ledger')
    receipts = cursor.fetchone()[0]
    cursor.execute('SELECT slot,name,quantity,metadata FROM opx77_inventory_items ORDER BY inventory_id,slot')
    items = cursor.fetchall()
    cursor.execute("SELECT balance FROM opx77_company_accounts WHERE kind='job' AND group_key='test'")
    company = int(cursor.fetchone()[0])
    cursor.execute('SELECT COUNT(*) FROM opx77_company_ledger')
    company_receipts = cursor.fetchone()[0]
    cursor.execute('SELECT id,token FROM opx77_crafting_orders ORDER BY id')
    orders = cursor.fetchall()
    cursor.execute("SELECT JSON_VALUE(money,'$.EDDIES') FROM opx77_characters WHERE citizen_id='SELLTEST'")
    peer = cursor.fetchone()
    peer = int(peer[0]) if peer else 0
    cursor.execute('SELECT plate,purchase_op FROM opx77_vehicles ORDER BY plate')
    vehicles = cursor.fetchall()
    cursor.execute('SELECT op_id,phase,amount,paid FROM opx77_dealership_payouts ORDER BY op_id,phase')
    obligations = cursor.fetchall()
    cursor.execute('SELECT clothing FROM opx77_character_clothing')
    clothing = cursor.fetchall()
    cursor.execute('SELECT source,amount FROM opx77_underworld_ledger ORDER BY id')
    minted = cursor.fetchall()
    cursor.execute('SELECT id,clean,collected,durable_version FROM opx77_underworld_batches ORDER BY id')
    batches = cursor.fetchall()
    cursor.execute('SELECT store_id,charges FROM opx77_underworld_registers ORDER BY store_id')
    tills = cursor.fetchall()
    return balance, notes, receipts, items, company, company_receipts, orders, peer, vehicles, obligations, clothing, minted, batches, tills


def execute(cursor, statement):
  assert statement['query'].count('?') == len(statement['values'])
  assert len(statement['values']) <= 64
  cursor.execute(statement['query'].replace('?', '%s'), tuple(statement['values']))


checks = 0
for case in plans['cases']:
  reset(case)
  original = state()
  # Closing a connection midway simulates a process dying before COMMIT. Test
  # every boundary, including after each inventory INSERT chunk and receipt.
  for boundary in range(1, len(case['statements']) + 1):
    interrupted = pymysql.connect(**settings)
    interrupted.begin()
    with interrupted.cursor() as cursor:
      for statement in case['statements'][:boundary]:
        execute(cursor, statement)
    interrupted.close()
    assert state() == original, (case['name'], 'torn state at', boundary)
    checks += 1
  connection.begin()
  with connection.cursor() as cursor:
    for statement in case['statements']:
      execute(cursor, statement)
  connection.commit()
  committed = state()
  assert committed[0] + committed[1] + committed[4] + committed[7] == original[0] + original[1] + original[4] + original[7] - case.get('spent', 0), case['name']
  refused = case.get('refused') or case['name'] in ('insufficient', 'overflow')
  if refused:
    assert committed == original, (case['name'], 'refused operation changed state')
  else:
    assert committed[2] == (2 if case.get('peer') is not None else 1)
    with connection.cursor() as cursor:
      cursor.execute("SELECT balance_after FROM opx77_money_ledger WHERE citizen_id='ECONTEST'")
      assert int(cursor.fetchone()[0]) == committed[0]
  if case.get('underworld') == 'mint':
    assert committed[11] == (('robbery:test', 100),) and committed[13] == (('test', 0),)
  elif case.get('underworld') == 'batch':
    assert len(committed[12]) == 1 and committed[12][0][3] == 1 and not any(row[1] == 'dirty_eddies' for row in committed[3])
  elif case.get('underworld') == 'collect':
    assert committed[12][0][2] == 1 and committed[0] == 580
  if case.get('vehicle') == 'purchase':
    assert len(committed[8]) == 1 and len(committed[9]) == 2
  if case.get('clothing'):
    assert len(committed[10]) == 1
  if case.get('peer') is not None and not refused:
    assert committed[7] == case['peer'] + 100 and sum(row[2] for row in committed[3] if row[1] == 'water') == 3
  if case.get('multi'):
    assert sum(row[2] for row in committed[3] if row[1] == 'water') == 2
  if case.get('craft') == 'order':
    assert len(committed[6]) == 1
  elif case.get('craft') == 'collect':
    assert not committed[6] and any(row[1] == 'ammo_handgun' for row in committed[3])
  checks += 1
  if 'replay' in case:
    connection.begin()
    try:
      with connection.cursor() as cursor:
        for statement in case['replay']:
          execute(cursor, statement)
      connection.commit()
    except pymysql.IntegrityError:
      connection.rollback()
    assert state() == committed, (case['name'], 'replay changed money or items')
    checks += 1

# A guarded INSERT matching zero rows must not reuse an old receipt's effects.
case = plans['cases'][0]
reset(case)
connection.begin()
with connection.cursor() as cursor:
  for statement in case['statements']:
    execute(cursor, statement)
connection.commit()
with connection.cursor() as cursor:
  cursor.execute("UPDATE opx77_characters SET money='{\"EDDIES\":0}' WHERE citizen_id='ECONTEST'")
original = state()
connection.begin()
with connection.cursor() as cursor:
  for statement in case['replay']:
    execute(cursor, statement)
connection.commit()
assert state() == original, 'an absent new INSERT reused another attempt receipt'
checks += 1
# Company-only writers share the same receipt nonce rule as wallet participants.
def company_state():
  with connection.cursor() as cursor:
    cursor.execute('SELECT group_key,balance FROM opx77_company_accounts ORDER BY group_key')
    accounts = cursor.fetchall()
    cursor.execute('SELECT op_id,delta,balance_after,attempt_token FROM opx77_company_ledger ORDER BY op_id')
    return accounts, cursor.fetchall()

for case in plans['companyCases']:
  reset(dict(balance=0, notes=0, company=case['balance']))
  with connection.cursor() as cursor:
    cursor.execute("INSERT INTO opx77_company_accounts(kind,group_key,balance) VALUES('job','other',%s)", (case['target'],))
  original = company_state()
  for boundary in range(1, len(case['statements']) + 1):
    interrupted = pymysql.connect(**settings)
    interrupted.begin()
    with interrupted.cursor() as cursor:
      for statement in case['statements'][:boundary]:
        execute(cursor, statement)
    interrupted.close()
    assert company_state() == original, (case['name'], boundary)
    checks += 1
  connection.begin()
  with connection.cursor() as cursor:
    for statement in case['statements']:
      execute(cursor, statement)
  connection.commit()
  committed = company_state()
  if 'insufficient' in case['name'] or 'overflow' in case['name']:
    assert committed == original, case['name']
  elif case['name'] == 'move':
    assert sum(int(row[1]) for row in committed[0]) == sum(int(row[1]) for row in original[0])
    assert len(committed[1]) == 2
  else:
    expected = case['balance'] + (case['amount'] if case['name'] == 'credit' else -case['amount'])
    assert dict(committed[0])['test'] == expected and len(committed[1]) == 1
  checks += 1
  connection.begin()
  try:
    with connection.cursor() as cursor:
      for statement in case['replay']:
        execute(cursor, statement)
    connection.commit()
  except pymysql.IntegrityError:
    connection.rollback()
  assert company_state() == committed, ('company replay', case['name'])
  checks += 1
  # Force a previously successful debit's eligibility to become false. The old
  # receipt still exists, but its nonce cannot authorize the new attempt.
  if case['name'] in ('debit', 'move'):
    with connection.cursor() as cursor:
      cursor.execute("UPDATE opx77_company_accounts SET balance=0 WHERE group_key='test'")
    original = company_state()
    connection.begin()
    with connection.cursor() as cursor:
      for statement in case['replay']:
        execute(cursor, statement)
    connection.commit()
    assert company_state() == original, ('zero-row replay', case['name'])
    checks += 1

# A later ownership/payout statement failing must roll the already executed
# debit and car INSERT back too. This is a statement error, beyond disconnects.
case = next(case for case in plans['cases'] if case['name'] == 'vehicle-purchase')
reset(case)
with connection.cursor() as cursor:
  cursor.execute("INSERT INTO opx77_dealership_payouts(op_id,phase,kind,group_key,money_type,amount,plate) VALUES('integration:vehicle-purchase','company','job','test','EDDIES',80,'OLD')")
original = state()
connection.begin()
try:
  with connection.cursor() as cursor:
    for statement in case['statements']:
      execute(cursor, statement)
  raise AssertionError('forced payout collision did not fail')
except pymysql.IntegrityError:
  connection.rollback()
assert state() == original, 'payout failure left a debit or ownership committed'
checks += 1

# Independent connections must serialize their eligibility and arithmetic at
# the wallet row. This checks SQL row locks, beyond the VM's coroutine guard.
def concurrent_credit(statements):
  for attempt in range(5):
    writer = pymysql.connect(**settings)
    try:
      writer.begin()
      with writer.cursor() as cursor:
        for statement in statements:
          execute(cursor, statement)
      writer.commit()
      return
    except pymysql.OperationalError as failure:
      writer.rollback()
      if failure.args[0] != 1213 or attempt == 4:
        raise
    finally:
      writer.close()

for balance, expected in ((500, 508), (9007199254740988, 9007199254740991)):
  reset(dict(balance=balance, notes=0))
  with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(concurrent_credit, plans['concurrent']))
  after = state()
  assert after[0] == expected and after[2] == expected - balance, ('concurrent credits', balance, after)
  checks += 1

# Each order derives its deadline from the locked SQL tail, even when both
# application requests were prepared with the same stale shelf snapshot.
reset(dict(balance=500, notes=0))
for statements in plans['craftingSequential']:
  connection.begin()
  with connection.cursor() as cursor:
    for statement in statements:
      execute(cursor, statement)
  connection.commit()
with connection.cursor() as cursor:
  cursor.execute("SELECT TIMESTAMPDIFF(SECOND,MIN(ready_at),MAX(ready_at)) FROM opx77_crafting_orders WHERE bench='sequential'")
  assert cursor.fetchone()[0] >= 60, 'a stale shelf snapshot shortened the second craft'
checks += 1

print(f'InnoDB economy: {checks} crash boundaries, conservation, refusals and receipt replay checks passed ({database})')
# Only empty the fresh isolated schema; never DROP a database.
with connection.cursor() as cursor:
  for table in ('opx77_underworld_ledger', 'opx77_underworld_registers', 'opx77_underworld_batches', 'opx77_dealership_payouts', 'opx77_vehicles', 'opx77_character_clothing', 'opx77_crafting_orders', 'opx77_inventory_items', 'opx77_inventories', 'opx77_money_ledger', 'opx77_company_ledger', 'opx77_company_accounts', 'opx77_characters', 'opx77_users'):
    cursor.execute('DELETE FROM ' + table)
connection.close()
admin.close()
