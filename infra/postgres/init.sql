CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(100) NOT NULL UNIQUE,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    keycloak_id TEXT UNIQUE,
    username TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    email TEXT NOT NULL,
    extension TEXT NOT NULL,
    current_state TEXT NOT NULL DEFAULT 'OFFLINE'
        CHECK (current_state IN ('OFFLINE','READY','ON_CALL','WRAP','AWAY')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_agents_tenant ON agents (tenant_id, current_state);

CREATE TABLE skills (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    category TEXT,
    UNIQUE (tenant_id, name)
);

CREATE TABLE agent_skills (
    agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL,
    skill_id UUID NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
    proficiency SMALLINT NOT NULL CHECK (proficiency BETWEEN 1 AND 10),
    PRIMARY KEY (agent_id, skill_id)
);
CREATE INDEX idx_agent_skills_skill ON agent_skills (skill_id, proficiency DESC);

CREATE TABLE sip_trunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    proxy_host TEXT NOT NULL,
    proxy_port INT NOT NULL DEFAULT 5060,
    username TEXT,
    auth_password TEXT,
    max_concurrent_calls INT NOT NULL DEFAULT 30,
    codec_prefs TEXT[] NOT NULL DEFAULT '{ulaw,alaw,opus}',
    status TEXT NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','DEGRADED','OFFLINE')),
    priority INT NOT NULL DEFAULT 10,
    dispatcher_group INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE trunk_lcr_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trunk_id UUID NOT NULL REFERENCES sip_trunks(id) ON DELETE CASCADE,
    number_prefix TEXT NOT NULL,
    cost_per_minute NUMERIC(8,4) NOT NULL DEFAULT 0.0,
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE queues (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    required_skills JSONB NOT NULL DEFAULT '[]',
    strategy TEXT NOT NULL DEFAULT 'BEST_SKILL'
        CHECK (strategy IN ('BEST_SKILL','ROUND_ROBIN','LEAST_OCCUPIED')),
    sla_target_s INT NOT NULL DEFAULT 20,
    max_wait_s INT NOT NULL DEFAULT 300,
    overflow_action TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE campaigns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    dialing_mode TEXT NOT NULL DEFAULT 'PROGRESSIVE'
        CHECK (dialing_mode IN ('PROGRESSIVE','PREVIEW','PREDICTIVE')),
    status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT','SCHEDULED','ACTIVE','PAUSED','COMPLETED','ARCHIVED')),
    caller_id TEXT NOT NULL DEFAULT 'Unknown',
    trunk_id UUID REFERENCES sip_trunks(id),
    preview_timer_s INT NOT NULL DEFAULT 15,
    max_attempts INT NOT NULL DEFAULT 3,
    retry_delay_s INT NOT NULL DEFAULT 3600,
    target_abandon_rate NUMERIC(4,3) NOT NULL DEFAULT 0.03,
    schedule_start TIME,
    schedule_end TIME,
    timezone TEXT NOT NULL DEFAULT 'America/New_York',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

CREATE TABLE contacts (
    id UUID DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    phone_e164 TEXT NOT NULL,
    first_name TEXT,
    last_name TEXT,
    email TEXT,
    timezone TEXT DEFAULT 'America/New_York',
    dnc_flagged BOOLEAN NOT NULL DEFAULT false,
    custom_fields JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, tenant_id)
) PARTITION BY HASH (tenant_id);

CREATE TABLE contacts_p0 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE contacts_p1 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 1);
CREATE TABLE contacts_p2 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 2);
CREATE TABLE contacts_p3 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 3);
CREATE TABLE contacts_p4 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 4);
CREATE TABLE contacts_p5 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 5);
CREATE TABLE contacts_p6 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 6);
CREATE TABLE contacts_p7 PARTITION OF contacts FOR VALUES WITH (MODULUS 8, REMAINDER 7);

CREATE UNIQUE INDEX idx_contacts_phone_tenant ON contacts (tenant_id, phone_e164);

CREATE TABLE contact_campaign_assignments (
    contact_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    campaign_id UUID NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'QUEUED'
        CHECK (status IN ('QUEUED','DIALING','REACHED','CALLBACK','NO_ANSWER','DNC_BLOCKED','MAX_ATTEMPTS','COMPLETED')),
    priority INT NOT NULL DEFAULT 0,
    attempts_count INT NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ,
    PRIMARY KEY (contact_id, campaign_id)
);
CREATE INDEX idx_cca_queue ON contact_campaign_assignments
    (campaign_id, next_attempt_at) WHERE status = 'QUEUED';

CREATE TABLE disposition_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    campaign_id UUID REFERENCES campaigns(id),
    label TEXT NOT NULL,
    code TEXT NOT NULL,
    requires_callback BOOLEAN NOT NULL DEFAULT false,
    dnc_flag BOOLEAN NOT NULL DEFAULT false,
    sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE call_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    channel_id TEXT,
    contact_id UUID,
    agent_id UUID REFERENCES agents(id),
    campaign_id UUID REFERENCES campaigns(id),
    queue_id UUID REFERENCES queues(id),
    direction TEXT NOT NULL CHECK (direction IN ('INBOUND','OUTBOUND')),
    disposition_code TEXT,
    notes TEXT,
    callback_at TIMESTAMPTZ,
    dnc_flagged BOOLEAN NOT NULL DEFAULT false,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    duration_s INT,
    recording_path TEXT,
    sf_task_id TEXT
);
CREATE INDEX idx_call_records_agent ON call_records (agent_id, started_at DESC);
CREATE INDEX idx_call_records_campaign ON call_records (campaign_id, started_at DESC);
CREATE INDEX idx_call_records_tenant ON call_records (tenant_id, started_at DESC);

CREATE TABLE recording_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    call_record_id UUID NOT NULL REFERENCES call_records(id),
    s3_path TEXT NOT NULL UNIQUE,
    duration_s INT,
    file_size_bytes BIGINT,
    encrypted BOOLEAN NOT NULL DEFAULT true,
    kms_key_ref TEXT NOT NULL DEFAULT 'vault-transit',
    checksum_sha256 TEXT NOT NULL,
    retention_until DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_recordings_call ON recording_files (call_record_id);
CREATE INDEX idx_recordings_tenant ON recording_files (tenant_id, created_at DESC);

CREATE TABLE dnc_lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    source_type TEXT NOT NULL DEFAULT 'INTERNAL'
        CHECK (source_type IN ('INTERNAL','NATIONAL','STATE','FEDERAL')),
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE dnc_numbers (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID,
    phone_e164 TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'INTERNAL',
    list_id UUID REFERENCES dnc_lists(id),
    added_by UUID REFERENCES agents(id),
    added_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_dnc_phone ON dnc_numbers (phone_e164);
CREATE UNIQUE INDEX idx_dnc_unique
    ON dnc_numbers (phone_e164, COALESCE(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid));

CREATE TABLE crm_connections (
    tenant_id UUID PRIMARY KEY REFERENCES tenants(id),
    provider TEXT NOT NULL DEFAULT 'SALESFORCE',
    instance_url TEXT NOT NULL,
    connected_sf_user TEXT,
    access_token_vault_path TEXT NOT NULL,
    refresh_token_vault_path TEXT NOT NULL,
    connected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_sync_at TIMESTAMPTZ
);

CREATE TABLE crm_sync_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    call_record_id UUID NOT NULL REFERENCES call_records(id),
    event_type TEXT NOT NULL DEFAULT 'CALL_COMPLETED',
    payload JSONB NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','SYNCED','DEAD_LETTER')),
    retry_count INT NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sf_record_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_crm_sync_pending ON crm_sync_events (next_retry_at) WHERE status = 'PENDING';

-- TimescaleDB hypertables
CREATE TABLE campaign_stats (
    time TIMESTAMPTZ NOT NULL,
    tenant_id UUID NOT NULL,
    campaign_id UUID NOT NULL,
    calls_dialed INT NOT NULL DEFAULT 0,
    calls_answered INT NOT NULL DEFAULT 0,
    calls_abandoned INT NOT NULL DEFAULT 0,
    calls_human INT NOT NULL DEFAULT 0,
    calls_machine INT NOT NULL DEFAULT 0,
    dial_ratio NUMERIC(4,2),
    abandon_rate NUMERIC(6,4)
);
SELECT create_hypertable('campaign_stats', 'time', chunk_time_interval => INTERVAL '1 hour');

CREATE TABLE queue_stats (
    time TIMESTAMPTZ NOT NULL,
    tenant_id UUID NOT NULL,
    queue_id UUID NOT NULL,
    calls_queued INT NOT NULL DEFAULT 0,
    calls_answered INT NOT NULL DEFAULT 0,
    calls_abandoned INT NOT NULL DEFAULT 0,
    avg_wait_s NUMERIC(8,2),
    sla_pct NUMERIC(5,2)
);
SELECT create_hypertable('queue_stats', 'time', chunk_time_interval => INTERVAL '1 hour');

CREATE TABLE cdr (
    id UUID DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    campaign_id UUID,
    agent_id UUID,
    queue_id UUID,
    phone TEXT,
    direction TEXT,
    disposition TEXT,
    duration_s INT,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    amd_result TEXT,
    trunk_id UUID
);
SELECT create_hypertable('cdr', 'started_at', chunk_time_interval => INTERVAL '1 day');

-- Continuous aggregates
CREATE MATERIALIZED VIEW campaign_stats_5min
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 minutes', time) AS bucket,
    tenant_id, campaign_id,
    sum(calls_dialed) AS calls_dialed,
    sum(calls_answered) AS calls_answered,
    sum(calls_abandoned) AS calls_abandoned,
    avg(abandon_rate) AS avg_abandon_rate,
    avg(dial_ratio) AS avg_dial_ratio
FROM campaign_stats
GROUP BY bucket, tenant_id, campaign_id;

-- Row-Level Security
ALTER TABLE campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON campaigns
    USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
CREATE POLICY tenant_isolation ON contacts
    USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
CREATE POLICY tenant_isolation ON call_records
    USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
CREATE POLICY tenant_isolation ON agents
    USING (tenant_id = current_setting('app.current_tenant_id', true)::uuid);
