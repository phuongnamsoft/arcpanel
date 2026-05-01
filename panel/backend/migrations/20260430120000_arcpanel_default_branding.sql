-- Migrate default product name for installs that still use the old seed.
UPDATE settings
SET value = 'ArcPanel', updated_at = NOW()
WHERE key = 'panel_name' AND value = 'DockPanel';

-- New mail domains default DKIM selector (existing rows unchanged).
ALTER TABLE mail_domains ALTER COLUMN dkim_selector SET DEFAULT 'arcpanel';
