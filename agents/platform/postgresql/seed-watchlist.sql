-- Watchlist seed for user-joan
-- Run via: kubectl exec -n postgresql deployment/postgresql -- psql -U agents -d agents -f /tmp/seed-watchlist.sql
-- Or paste directly: kubectl exec -n postgresql deployment/postgresql -- psql -U agents -d agents -c "<SQL>"

INSERT INTO watchlist (user_id, ticker, label, asset_type) VALUES
  ('user-joan', 'XPEV',    'XPeng',              'stock'),
  ('user-joan', '1211.HK', 'BYD',                'stock'),
  ('user-joan', 'CDR.WA',  'CD Projekt',         'stock'),
  ('user-joan', 'ITX.MC',  'Inditex',            'stock'),
  ('user-joan', 'MSFT',    'Microsoft',          'stock'),
  ('user-joan', 'OKLO',    'Oklo',               'stock'),
  ('user-joan', '0700.HK', 'Tencent',            'stock'),
  ('user-joan', 'TSLA',    'Tesla',              'stock'),
  ('user-joan', 'UBI.PA',  'Ubisoft',            'stock'),
  ('user-joan', '1810.HK', 'Xiaomi',             'stock'),
  ('user-joan', 'CHIQ',    'China Consumer ETF', 'etf'),
  ('user-joan', 'SGLD.L',  'Gold ETC',           'etc'),
  ('user-joan', 'RBOT.L',  'Robo Global ETF',    'etf'),
  ('user-joan', 'EIMI.L',  'iShares EM IMI',     'etf'),
  ('user-joan', 'ROBO',    'ROBO Global ETF',    'etf'),
  ('user-joan', 'REMX',    'VanEck Rare Earth',  'etf'),
  ('user-joan', 'VEUR.L',  'Vanguard Europe',    'etf'),
  ('user-joan', 'WDEF.L',  'WisdomTree Def',     'etf'),
  ('user-joan', 'NCLR.L',  'iShares Nuclear',    'etf'),
  ('user-joan', 'XAIX.DE', 'Xtrackers AI ETF',   'etf')
ON CONFLICT (user_id, ticker) DO NOTHING;
