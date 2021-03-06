-------------------------------------------------------------------------------
--                             million trillion trillion
--                             |         trillion trillion
--                             |         |               trillion
--                             |         |               |   billion
--                             |         |               |   |   million
--                             |         |               |   |   |   thousand
--                             |         |               |   |   |   |
-- numeric(35,2) maxes out at $999,999,999,999,999,999,999,999,999,999,999.00.


CREATE EXTENSION pg_trgm;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';

\i sql/enforce-utc.sql

\i sql/utils.sql

\i sql/update_counts.sql


-- database metadata
CREATE TABLE db_meta (key text PRIMARY KEY, value jsonb);
INSERT INTO db_meta (key, value) VALUES ('schema_version', '37'::jsonb);


-- app configuration
CREATE TABLE app_conf (key text PRIMARY KEY, value jsonb);


-- participants -- user accounts

CREATE TYPE participant_kind AS ENUM ('individual', 'organization', 'group', 'community');
CREATE TYPE participant_status AS ENUM ('stub', 'active', 'closed');

CREATE TABLE participants
( id                    bigserial               PRIMARY KEY
, username              text                    NOT NULL
, email                 text
, email_lang            text
, password              text
, password_mtime        timestamptz
, kind                  participant_kind
, status                participant_status      NOT NULL DEFAULT 'stub'
, session_token         text
, session_expires       timestamptz             DEFAULT (now() + INTERVAL '6 hours')
, join_time             timestamptz             DEFAULT NULL

, balance               numeric(35,2)           NOT NULL DEFAULT 0.0
, goal                  numeric(35,2)           DEFAULT NULL
, mangopay_user_id      text                    DEFAULT NULL UNIQUE
, mangopay_wallet_id    text                    DEFAULT NULL

, hide_giving           boolean                 NOT NULL DEFAULT FALSE
, hide_receiving        boolean                 NOT NULL DEFAULT FALSE
, hide_from_search      int                     NOT NULL DEFAULT 0

, avatar_url            text
, giving                numeric(35,2)           NOT NULL DEFAULT 0
, receiving             numeric(35,2)           NOT NULL DEFAULT 0
, taking                numeric(35,2)           NOT NULL DEFAULT 0
, npatrons              integer                 NOT NULL DEFAULT 0

, email_notif_bits      int                     NOT NULL DEFAULT 2147483647
, pending_notifs        int                     NOT NULL DEFAULT 0 CHECK (pending_notifs >= 0)

, avatar_src            text
, avatar_email          text

, profile_nofollow      boolean                 DEFAULT TRUE
, profile_noindex       int                     NOT NULL DEFAULT 2
, hide_from_lists       int                     NOT NULL DEFAULT 0

, privileges            int                     NOT NULL DEFAULT 0

, is_suspended          boolean

, nsubscribers          int                     NOT NULL DEFAULT 0

, allow_invoices        boolean

, throttle_takes        boolean                 NOT NULL DEFAULT TRUE

, CONSTRAINT balance_chk CHECK (NOT ((status <> 'active' OR kind IN ('group', 'community')) AND balance <> 0))
, CONSTRAINT giving_chk CHECK (NOT (kind IN ('group', 'community') AND giving <> 0))
, CONSTRAINT goal_chk CHECK (NOT (kind IN ('group', 'community') AND status='active' AND goal IS NOT NULL AND goal <= 0))
, CONSTRAINT join_time_chk CHECK ((status='stub') = (join_time IS NULL))
, CONSTRAINT kind_chk CHECK ((status='stub') = (kind IS NULL))
, CONSTRAINT mangopay_chk CHECK (NOT ((mangopay_user_id IS NULL OR mangopay_wallet_id IS NULL) AND balance <> 0))
, CONSTRAINT secret_team_chk CHECK (NOT (kind IN ('group', 'community') AND hide_receiving))
 );

CREATE UNIQUE INDEX ON participants (lower(username));
CREATE UNIQUE INDEX participants_email_key ON participants (lower(email));

CREATE INDEX username_trgm_idx ON participants
    USING gist(lower(username) gist_trgm_ops)
    WHERE status = 'active';

CREATE INDEX participants_join_time_idx ON participants (join_time)
    WHERE join_time IS NOT NULL;

CREATE FUNCTION fill_username() RETURNS trigger AS $$
    BEGIN
        NEW.username = '~'||NEW.id::text;
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER fill_username BEFORE INSERT ON participants
    FOR EACH ROW WHEN (NEW.username IS NULL) EXECUTE PROCEDURE fill_username();


-- elsewhere -- social network accounts attached to participants

CREATE TABLE elsewhere
( id                    serial          PRIMARY KEY
, participant           bigint          NOT NULL REFERENCES participants
, platform              text            NOT NULL
, user_id               text
, user_name             text
-- Note: we use "user_name" instead of "username" to avoid having the same
--       column name in the participants and elsewhere tables.
, display_name          text
, email                 text
, avatar_url            text
, is_team               boolean         NOT NULL DEFAULT FALSE
, extra_info            json
, token                 json
, connect_token         text
, connect_expires       timestamptz
, domain                text            NOT NULL -- NULL would break the unique indexes
, UNIQUE (participant, platform)
, CONSTRAINT user_id_chk CHECK (user_id IS NOT NULL OR domain <> '' AND user_name IS NOT NULL)
);

CREATE UNIQUE INDEX elsewhere_user_id_key ON elsewhere (platform, domain, user_id);
CREATE UNIQUE INDEX elsewhere_user_name_key ON elsewhere (lower(user_name), platform, domain);


-- oauth credentials

CREATE TABLE oauth_apps
( platform   text          NOT NULL
, domain     text          NOT NULL
, key        text          NOT NULL
, secret     text          NOT NULL
, ctime      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, UNIQUE (platform, domain, key)
);


-- tips -- all times a participant elects to tip another

CREATE TYPE donation_period AS ENUM ('weekly', 'monthly', 'yearly');

CREATE TABLE tips
( id           serial           PRIMARY KEY
, ctime        timestamptz      NOT NULL
, mtime        timestamptz      NOT NULL DEFAULT CURRENT_TIMESTAMP
, tipper       bigint           NOT NULL REFERENCES participants
, tippee       bigint           NOT NULL REFERENCES participants
, amount       numeric(35,2)    NOT NULL CHECK (amount >= 0)
, is_funded    boolean          NOT NULL DEFAULT false
, period       donation_period  NOT NULL
, periodic_amount numeric(35,2) NOT NULL
, CONSTRAINT no_self_tipping CHECK (tipper <> tippee)
 );

CREATE INDEX tips_tipper_idx ON tips (tipper, mtime DESC);
CREATE INDEX tips_tippee_idx ON tips (tippee, mtime DESC);

CREATE VIEW current_tips AS
    SELECT DISTINCT ON (tipper, tippee) *
      FROM tips
  ORDER BY tipper, tippee, mtime DESC;

-- Allow updating is_funded via the current_tips view for convenience
CREATE FUNCTION update_tip() RETURNS trigger AS $$
    BEGIN
        UPDATE tips
           SET is_funded = NEW.is_funded
         WHERE id = NEW.id;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_current_tip INSTEAD OF UPDATE ON current_tips
    FOR EACH ROW EXECUTE PROCEDURE update_tip();


-- invoices

CREATE TYPE invoice_nature AS ENUM ('expense');

CREATE TYPE invoice_status AS ENUM
    ('pre', 'canceled', 'new', 'retracted', 'accepted', 'paid', 'rejected');

CREATE TABLE invoices
( id            serial            PRIMARY KEY
, ctime         timestamptz       NOT NULL DEFAULT CURRENT_TIMESTAMP
, sender        bigint            NOT NULL REFERENCES participants
, addressee     bigint            NOT NULL REFERENCES participants
, nature        invoice_nature    NOT NULL
, amount        numeric(35,2)     NOT NULL CHECK (amount > 0)
, description   text              NOT NULL
, details       text
, documents     jsonb             NOT NULL
, status        invoice_status    NOT NULL
);

CREATE TABLE invoice_events
( id            serial            PRIMARY KEY
, invoice       int               NOT NULL REFERENCES invoices
, participant   bigint            NOT NULL REFERENCES participants
, ts            timestamptz       NOT NULL DEFAULT CURRENT_TIMESTAMP
, status        invoice_status    NOT NULL
, message       text
);


-- transfers -- balance transfers from one user to another

CREATE TYPE transfer_context AS ENUM
    ('tip', 'take', 'final-gift', 'refund', 'expense');

CREATE TYPE transfer_status AS ENUM ('pre', 'failed', 'succeeded');

CREATE TABLE transfers
( id          serial              PRIMARY KEY
, timestamp   timestamptz         NOT NULL DEFAULT CURRENT_TIMESTAMP
, tipper      bigint              NOT NULL REFERENCES participants
, tippee      bigint              NOT NULL REFERENCES participants
, amount      numeric(35,2)       NOT NULL CHECK (amount > 0)
, context     transfer_context    NOT NULL
, team        bigint              REFERENCES participants
, status      transfer_status     NOT NULL
, error       text
, refund_ref  bigint              REFERENCES transfers
, invoice     int                 REFERENCES invoices
, CONSTRAINT team_chk CHECK (NOT (context='take' AND team IS NULL))
, CONSTRAINT self_chk CHECK (tipper <> tippee)
, CONSTRAINT expense_chk CHECK (NOT (context='expense' AND invoice IS NULL))
 );

CREATE INDEX transfers_tipper_idx ON transfers (tipper);
CREATE INDEX transfers_tippee_idx ON transfers (tippee);


-- paydays -- payday events, stats about them

CREATE TABLE paydays
( id                    serial           PRIMARY KEY
, ts_start              timestamptz      NOT NULL DEFAULT CURRENT_TIMESTAMP
, ts_end                timestamptz      UNIQUE NOT NULL DEFAULT '1970-01-01T00:00:00+00'::timestamptz
, nparticipants         bigint           NOT NULL DEFAULT 0
, ntippers              bigint           NOT NULL DEFAULT 0
, ntippees              bigint           NOT NULL DEFAULT 0
, ntips                 bigint           NOT NULL DEFAULT 0
, ntransfers            bigint           NOT NULL DEFAULT 0
, transfer_volume       numeric(35,2)    NOT NULL DEFAULT 0.00
, ntakes                bigint           NOT NULL DEFAULT 0
, take_volume           numeric(35,2)    NOT NULL DEFAULT 0.00
, nactive               bigint           NOT NULL DEFAULT 0
, nusers                bigint           NOT NULL DEFAULT 0
, week_deposits         numeric(35,2)    NOT NULL DEFAULT 0
, week_withdrawals      numeric(35,2)    NOT NULL DEFAULT 0
, transfer_volume_refunded   numeric(35,2)
, week_deposits_refunded     numeric(35,2)
, week_withdrawals_refunded  numeric(35,2)
 );


-- exchange routes -- how money moves in and out of Liberapay

CREATE TYPE payment_net AS ENUM
    ('mango-ba', 'mango-bw', 'mango-cc');

CREATE TABLE exchange_routes
( id            serial         PRIMARY KEY
, participant   bigint         NOT NULL REFERENCES participants
, network       payment_net    NOT NULL
, address       text           NOT NULL CHECK (address <> '')
, error         text           NOT NULL
, one_off       boolean        NOT NULL
, UNIQUE (participant, network, address)
);

CREATE VIEW current_exchange_routes AS
    SELECT DISTINCT ON (participant, network) *
      FROM exchange_routes
  ORDER BY participant, network, id DESC;

CREATE CAST (current_exchange_routes AS exchange_routes) WITH INOUT;


-- exchanges -- when a participant moves cash between Liberapay and their bank

CREATE TYPE exchange_status AS ENUM ('pre', 'created', 'failed', 'succeeded');

CREATE TABLE exchanges
( id                serial               PRIMARY KEY
, timestamp         timestamptz          NOT NULL DEFAULT CURRENT_TIMESTAMP
, amount            numeric(35,2)        NOT NULL CHECK (amount <> 0)
, fee               numeric(35,2)        NOT NULL
, participant       bigint               NOT NULL REFERENCES participants
, recorder          bigint               REFERENCES participants
, note              text
, status            exchange_status      NOT NULL
, route             bigint               NOT NULL REFERENCES exchange_routes
, vat               numeric(35,2)        NOT NULL
, refund_ref        bigint               REFERENCES exchanges
 );

CREATE INDEX exchanges_participant_idx ON exchanges (participant);


-- communities -- groups of participants

CREATE TABLE communities
( id             bigserial     PRIMARY KEY
, name           text          UNIQUE NOT NULL
, nmembers       int           NOT NULL DEFAULT 0
, ctime          timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, creator        bigint        NOT NULL REFERENCES participants
, lang           text          NOT NULL
, participant    bigint        NOT NULL REFERENCES participants
);

CREATE UNIQUE INDEX ON communities (lower(name));

CREATE INDEX community_trgm_idx ON communities
    USING gist(name gist_trgm_ops);

CREATE TABLE community_memberships
( participant   bigint         NOT NULL REFERENCES participants
, community     bigint         NOT NULL REFERENCES communities
, ctime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, mtime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, is_on         boolean        NOT NULL
, UNIQUE (participant, community)
);

CREATE TRIGGER update_community_nmembers
    BEFORE INSERT OR UPDATE OR DELETE ON community_memberships
    FOR EACH ROW
    EXECUTE PROCEDURE update_community_nmembers();


-- subscriptions

CREATE TABLE subscriptions
( id            bigserial      PRIMARY KEY
, publisher     bigint         NOT NULL REFERENCES participants
, subscriber    bigint         NOT NULL REFERENCES participants
, ctime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, mtime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, is_on         boolean        NOT NULL
, token         text
, UNIQUE (publisher, subscriber)
);

CREATE TRIGGER update_nsubscribers
    BEFORE INSERT OR UPDATE OR DELETE ON subscriptions
    FOR EACH ROW
    EXECUTE PROCEDURE update_nsubscribers();


-- takes -- how members of a team share the money it receives

CREATE TABLE takes
( id                serial               PRIMARY KEY
, ctime             timestamptz          NOT NULL
, mtime             timestamptz          NOT NULL DEFAULT CURRENT_TIMESTAMP
, member            bigint               NOT NULL REFERENCES participants
, team              bigint               NOT NULL REFERENCES participants
, amount            numeric(35,2)        DEFAULT 1
, recorder          bigint               NOT NULL REFERENCES participants
, CONSTRAINT not_negative CHECK (amount IS NULL OR amount >= 0)
 );

CREATE OR REPLACE FUNCTION check_member() RETURNS trigger AS $$
    DECLARE
        m participants;
    BEGIN
        m := (SELECT p.*::participants FROM participants p WHERE id = NEW.member);
        IF (m.kind IN ('group', 'community')) THEN
            RAISE 'cannot add a group account to a team';
        END IF;
        IF (m.status <> 'active') THEN
            RAISE 'cannot add an inactive user to a team';
        END IF;
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_member BEFORE INSERT ON takes FOR EACH ROW
    EXECUTE PROCEDURE check_member();

CREATE VIEW current_takes AS
    SELECT * FROM (
         SELECT DISTINCT ON (member, team) t.*
           FROM takes t
       ORDER BY member, team, mtime DESC
    ) AS anon WHERE amount IS NOT NULL;


-- log of participant events

CREATE TABLE events
( id           bigserial     PRIMARY KEY
, ts           timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, participant  bigint        NOT NULL REFERENCES participants
, type         text          NOT NULL
, payload      jsonb
, recorder     bigint        REFERENCES participants
 );

CREATE INDEX events_participant_idx ON events (participant, type);


-- email addresses

CREATE TABLE emails
( id                serial         PRIMARY KEY
, address           text           NOT NULL
, verified          boolean        CHECK (verified IS NOT FALSE)
, nonce             text
, added_time        timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, verified_time     timestamptz
, participant       bigint         NOT NULL REFERENCES participants
, UNIQUE (participant, address)
 );

-- A verified email address can't be linked to multiple participants.
-- However, an *un*verified address *can* be linked to multiple
-- participants. We implement this by using NULL instead of FALSE for the
-- unverified state, hence the check constraint on verified.
CREATE UNIQUE INDEX emails_address_verified_key ON emails (lower(address), verified);


-- profile statements

CREATE TYPE stmt_type AS ENUM ('profile', 'sidebar', 'subtitle');

CREATE TABLE statements
( participant    bigint      NOT NULL REFERENCES participants
, type           stmt_type   NOT NULL
, lang           text        NOT NULL
, content        text        NOT NULL CHECK (content <> '')
, search_vector  tsvector
, search_conf    regconfig   NOT NULL
, UNIQUE (participant, type, lang)
);

CREATE INDEX statements_fts_idx ON statements USING gist(search_vector);

CREATE TRIGGER search_vector_update
    BEFORE INSERT OR UPDATE ON statements
    FOR EACH ROW EXECUTE PROCEDURE
    tsvector_update_trigger_column(search_vector, search_conf, content);


-- emails waiting to be sent

CREATE TABLE email_queue
( id            serial   PRIMARY KEY
, participant   bigint   NOT NULL REFERENCES participants
, spt_name      text     NOT NULL
, context       bytea    NOT NULL
);


-- web notifications waiting to be displayed

CREATE TABLE notification_queue
( id            serial   PRIMARY KEY
, participant   bigint   NOT NULL REFERENCES participants
, event         text     NOT NULL
, context       bytea    NOT NULL
, is_new        boolean  NOT NULL DEFAULT TRUE
);


-- cache of participant balances at specific times

CREATE TABLE balances_at
( participant  bigint         NOT NULL REFERENCES participants
, at           timestamptz    NOT NULL
, balance      numeric(35,2)  NOT NULL
, UNIQUE (participant, at)
);


-- all the money that has ever entered the system

CREATE TABLE cash_bundles
( id           bigserial      PRIMARY KEY
, owner        bigint         REFERENCES participants
, origin       bigint         NOT NULL REFERENCES exchanges
, amount       numeric(35,2)  NOT NULL CHECK (amount > 0)
, ts           timestamptz    NOT NULL
, withdrawal   int            REFERENCES exchanges
, CONSTRAINT in_or_out CHECK ((owner IS NULL) <> (withdrawal IS NULL))
);

CREATE INDEX cash_bundles_owner_idx ON cash_bundles (owner);


-- whitelist (via profile_noindex) of noteworthy organizational donors

CREATE OR REPLACE VIEW sponsors AS
    SELECT *
      FROM participants p
     WHERE status = 'active'
       AND kind = 'organization'
       AND giving > receiving
       AND giving >= 10
       AND hide_from_lists = 0
       AND profile_noindex = 0
    ;


-- newsletters

CREATE TABLE newsletters
( id              bigserial     PRIMARY KEY
, ctime           timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, sender          bigint        NOT NULL REFERENCES participants
);

CREATE TABLE newsletter_texts
( id              bigserial     PRIMARY KEY
, newsletter      bigint        NOT NULL REFERENCES newsletters
, lang            text          NOT NULL
, subject         text          NOT NULL CHECK (subject <> '')
, body            text          NOT NULL CHECK (body <> '')
, ctime           timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, scheduled_for   timestamptz
, sent_at         timestamptz
, sent_count      int
, UNIQUE (newsletter, lang)
);

CREATE INDEX newsletter_texts_not_sent_idx
          ON newsletter_texts (scheduled_for ASC)
       WHERE sent_at IS NULL AND scheduled_for IS NOT NULL;


-- composite types, keep this at the end of the file

\i sql/composites.sql
