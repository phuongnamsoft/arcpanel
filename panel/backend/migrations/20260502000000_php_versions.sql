CREATE TABLE php_versions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id      UUID NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    version        VARCHAR(10) NOT NULL,
    status         VARCHAR(20) NOT NULL DEFAULT 'installing',
    install_method VARCHAR(10) NOT NULL DEFAULT 'native',
    extensions     TEXT[]      NOT NULL DEFAULT '{}',
    error_message  TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (server_id, version)
);

CREATE INDEX idx_php_versions_server_id ON php_versions(server_id);
CREATE INDEX idx_php_versions_status ON php_versions(server_id, status);
