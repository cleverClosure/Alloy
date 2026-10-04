-- Author: Timur Isaev

PRAGMA application_id = 1095519321;
PRAGMA user_version = 1;

CREATE TABLE catalog_metadata (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version TEXT NOT NULL
);
INSERT INTO catalog_metadata(singleton, schema_version)
VALUES (1, '1.0');

CREATE TABLE objects (
    digest TEXT PRIMARY KEY,
    size INTEGER NOT NULL CHECK (size >= 0),
    refcount INTEGER NOT NULL CHECK (refcount >= 0)
) WITHOUT ROWID;

CREATE TABLE generations (
    game_id TEXT NOT NULL,
    generation_id TEXT NOT NULL,
    manifest_digest TEXT NOT NULL,
    layer_count INTEGER NOT NULL CHECK (layer_count >= 0),
    PRIMARY KEY (game_id, generation_id)
) WITHOUT ROWID;

CREATE TABLE generation_layers (
    game_id TEXT NOT NULL,
    generation_id TEXT NOT NULL,
    layer_index INTEGER NOT NULL CHECK (layer_index >= 0),
    digest TEXT NOT NULL REFERENCES objects(digest),
    PRIMARY KEY (game_id, generation_id, layer_index),
    FOREIGN KEY (game_id, generation_id)
        REFERENCES generations(game_id, generation_id)
        ON DELETE CASCADE
) WITHOUT ROWID;
CREATE INDEX generation_layers_digest
    ON generation_layers(digest);

CREATE TABLE generation_references (
    game_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (
        kind IN ('active', 'rollback', 'candidate')
    ),
    generation_id TEXT NOT NULL,
    manifest_digest TEXT NOT NULL,
    PRIMARY KEY (game_id, kind),
    FOREIGN KEY (game_id, generation_id)
        REFERENCES generations(game_id, generation_id)
) WITHOUT ROWID;
CREATE INDEX generation_references_generation
    ON generation_references(game_id, generation_id);

CREATE TABLE leases (
    lease_id TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    generation_id TEXT NOT NULL,
    manifest_digest TEXT NOT NULL,
    process_id INTEGER NOT NULL CHECK (process_id > 0),
    start_time_seconds INTEGER NOT NULL CHECK (start_time_seconds >= 0),
    start_time_microseconds INTEGER NOT NULL CHECK (
        start_time_microseconds >= 0
        AND start_time_microseconds < 1000000
    ),
    created_at_unix_seconds INTEGER NOT NULL,
    object_count INTEGER NOT NULL CHECK (object_count > 0),
    FOREIGN KEY (game_id, generation_id)
        REFERENCES generations(game_id, generation_id)
) WITHOUT ROWID;
CREATE INDEX leases_generation
    ON leases(game_id, generation_id);

CREATE TABLE lease_objects (
    lease_id TEXT NOT NULL REFERENCES leases(lease_id) ON DELETE CASCADE,
    object_index INTEGER NOT NULL CHECK (object_index >= 0),
    digest TEXT NOT NULL REFERENCES objects(digest),
    PRIMARY KEY (lease_id, object_index)
) WITHOUT ROWID;
CREATE INDEX lease_objects_digest
    ON lease_objects(digest);

CREATE TABLE inventory (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    object_count INTEGER NOT NULL CHECK (object_count >= 0),
    object_bytes INTEGER NOT NULL CHECK (object_bytes >= 0),
    object_reference_count INTEGER NOT NULL CHECK (
        object_reference_count >= 0
    ),
    generation_count INTEGER NOT NULL CHECK (generation_count >= 0),
    reference_count INTEGER NOT NULL CHECK (reference_count >= 0),
    lease_count INTEGER NOT NULL CHECK (lease_count >= 0)
);
