/* ------------------------------------------------------------------------
 *
 * init.sql
 *      Creates config table and provides common utility functions
 *
 * Copyright (c) 2015-2016, Postgres Professional
 *
 * ------------------------------------------------------------------------
 */

/*
 * Pathman config
 *  relname - schema qualified relation name
 *  attname - partitioning key
 *  parttype - partitioning type:
 *      1 - HASH
 *      2 - RANGE
 *  range_interval - base interval for RANGE partitioning in string representation
 */
CREATE TABLE IF NOT EXISTS @extschema@.pathman_config (
	id				SERIAL PRIMARY KEY,
	relname			VARCHAR(127),
	attname			VARCHAR(127),
	parttype		INTEGER,
	range_interval	TEXT
);
SELECT pg_catalog.pg_extension_config_dump('@extschema@.pathman_config', '');

CREATE OR REPLACE FUNCTION @extschema@.on_create_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_created' LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_update_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_updated' LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.on_remove_partitions(relid OID)
RETURNS VOID AS 'pg_pathman', 'on_partitions_removed' LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.find_or_create_range_partition(relid OID, value ANYELEMENT)
RETURNS OID AS 'pg_pathman', 'find_or_create_range_partition' LANGUAGE C STRICT;

/* PathmanRange type */
CREATE OR REPLACE FUNCTION @extschema@.pathman_range_in(cstring)
    RETURNS PathmanRange
    AS 'pg_pathman'
    LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION @extschema@.pathman_range_out(PathmanRange)
    RETURNS cstring
    AS 'pg_pathman'
    LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION @extschema@.get_whole_range(relid OID)
    RETURNS PathmanRange
    AS 'pg_pathman'
    LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.range_value_cmp(range PathmanRange, value ANYELEMENT)
	RETURNS INTEGER
	AS 'pg_pathman'
	LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.range_lower(range PathmanRange, dummy ANYELEMENT)
	RETURNS ANYELEMENT
	AS 'pg_pathman'
	LANGUAGE C;

CREATE OR REPLACE FUNCTION @extschema@.range_upper(range PathmanRange, dummy ANYELEMENT)
	RETURNS ANYELEMENT
	AS 'pg_pathman'
	LANGUAGE C;

CREATE OR REPLACE FUNCTION @extschema@.range_oid(range PathmanRange)
	RETURNS OID
	AS 'pg_pathman'
	LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION @extschema@.range_partitions_list(parent_relid OID)
	RETURNS SETOF PATHMANRANGE AS 'pg_pathman'
	LANGUAGE C STRICT;

CREATE TYPE @extschema@.PathmanRange (
	internallength = 32,
	input = pathman_range_in,
	output = pathman_range_out
);

/*
 * Returns min and max values for specified RANGE partition.
 */
CREATE OR REPLACE FUNCTION @extschema@.get_range_partition_by_oid(
	parent_relid OID, partition_relid OID)
RETURNS PATHMANRANGE AS 'pg_pathman' LANGUAGE C STRICT;


/*
 * Returns N-th range (in form of array)
 */
CREATE OR REPLACE FUNCTION @extschema@.get_range_by_idx(
	parent_relid OID, idx INTEGER, dummy ANYELEMENT)
RETURNS ANYARRAY AS 'pg_pathman', 'get_range_by_idx' LANGUAGE C STRICT;

/*
 * Checks if range overlaps with existing partitions.
 * Returns TRUE if overlaps and FALSE otherwise.
 */
CREATE OR REPLACE FUNCTION @extschema@.check_overlap(
	parent_relid OID, range_min ANYELEMENT, range_max ANYELEMENT)
RETURNS BOOLEAN AS 'pg_pathman', 'check_overlap' LANGUAGE C STRICT;

/*
 * Copy rows to partitions
 */
CREATE OR REPLACE FUNCTION @extschema@.partition_data(
	p_parent regclass
	, p_invalidate_cache_on_error BOOLEAN DEFAULT FALSE
	, OUT p_total BIGINT)
AS
$$
DECLARE
	relname TEXT;
	rec RECORD;
	cnt BIGINT := 0;
BEGIN
	relname := @extschema@.validate_relname(p_parent);

	p_total := 0;

	/* Create partitions and copy rest of the data */
	RAISE NOTICE 'Copying data to partitions...';
	EXECUTE format('
				WITH part_data AS (
					DELETE FROM ONLY %s RETURNING *)
				INSERT INTO %s SELECT * FROM part_data'
				, relname
				, relname);
	GET DIAGNOSTICS p_total = ROW_COUNT;
	RETURN;

-- EXCEPTION WHEN others THEN
--     PERFORM on_remove_partitions(p_parent::regclass::integer);
--     RAISE EXCEPTION '% %', SQLERRM, SQLSTATE;
END
$$
LANGUAGE plpgsql;


/*
 * Disable pathman partitioning for specified relation
 */
CREATE OR REPLACE FUNCTION @extschema@.disable_partitioning(IN relation TEXT)
RETURNS VOID AS
$$
BEGIN
	relation := @extschema@.validate_relname(relation);

	DELETE FROM @extschema@.pathman_config WHERE relname = relation;
	PERFORM @extschema@.drop_triggers(relation);

	/* Notify backend about changes */
	PERFORM on_remove_partitions(relation::regclass::integer);
END
$$
LANGUAGE plpgsql;


/*
 * Returns attribute type name for relation
 */
CREATE OR REPLACE FUNCTION @extschema@.get_attribute_type_name(
	p_relation REGCLASS
	, p_attname TEXT
	, OUT p_atttype TEXT)
RETURNS TEXT AS
$$
BEGIN
	SELECT typname::TEXT INTO p_atttype
	FROM pg_type JOIN pg_attribute on atttypid = "oid"
	WHERE attrelid = p_relation::oid and attname = lower(p_attname);
END
$$
LANGUAGE plpgsql;


/*
 * Checks if attribute is nullable
 */
CREATE OR REPLACE FUNCTION @extschema@.is_attribute_nullable(
	p_relation REGCLASS
	, p_attname TEXT
	, OUT p_nullable BOOLEAN)
RETURNS BOOLEAN AS
$$
BEGIN
	SELECT NOT attnotnull INTO p_nullable
	FROM pg_type JOIN pg_attribute on atttypid = "oid"
	WHERE attrelid = p_relation::oid and attname = lower(p_attname);
END
$$
LANGUAGE plpgsql;


/*
 * Aggregates several common relation checks before partitioning. Suitable for every partitioning type.
 */
CREATE OR REPLACE FUNCTION @extschema@.common_relation_checks(
	p_relation REGCLASS
	, p_attribute TEXT)
RETURNS BOOLEAN AS
$$
DECLARE
	v_rec RECORD;
	is_referenced BOOLEAN;
BEGIN
	IF EXISTS (SELECT * FROM @extschema@.pathman_config WHERE relname::regclass = p_relation) THEN
		RAISE EXCEPTION 'Relation "%" has already been partitioned', p_relation;
	END IF;

	IF @extschema@.is_attribute_nullable(p_relation, p_attribute) THEN
		RAISE EXCEPTION 'Partitioning key ''%'' must be NOT NULL', p_attribute;
	END IF;

	/* Check if there are foreign keys reference to the relation */
	FOR v_rec IN (SELECT *
				  FROM pg_constraint WHERE confrelid = p_relation::regclass::oid)
	LOOP
		is_referenced := TRUE;
		RAISE WARNING 'Foreign key ''%'' references to the relation ''%''', v_rec.conname, p_relation;
	END LOOP;

	IF is_referenced THEN
		RAISE EXCEPTION 'Relation ''%'' is referenced from other relations', p_relation;
	END IF;

	RETURN TRUE;
END
$$
LANGUAGE plpgsql;

/*
 * Returns relname without quotes or something
 */
CREATE OR REPLACE FUNCTION @extschema@.get_plain_schema_and_relname(cls regclass, OUT schema TEXT, OUT relname TEXT)
AS
$$
BEGIN
	SELECT relnamespace::regnamespace, pg_class.relname FROM pg_class WHERE oid = cls::oid
	INTO schema, relname;
END
$$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION @extschema@.get_plain_relname(cls regclass)
RETURNS TEXT AS
$$
BEGIN
	RETURN relname FROM pg_class WHERE oid = cls::oid;
END
$$
LANGUAGE plpgsql;


/*
 * Validates relation name. It must be schema qualified
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relname(cls regclass)
RETURNS TEXT AS
$$
BEGIN
	RETURN @extschema@.get_schema_qualified_name(cls, '.');
END
$$
LANGUAGE plpgsql;


/*
 * Returns schema-qualified name for table
 */
CREATE OR REPLACE FUNCTION @extschema@.get_schema_qualified_name(
	cls REGCLASS
	, delimiter TEXT DEFAULT '_'
	, suffix TEXT DEFAULT '')
RETURNS TEXT AS
$$
BEGIN
	RETURN relnamespace::regnamespace || delimiter || quote_ident(relname || suffix) FROM pg_class WHERE oid = cls::oid;
END
$$
LANGUAGE plpgsql;

/*
 * Check if two relations have equal structures
 */
CREATE OR REPLACE FUNCTION @extschema@.validate_relations_equality(relation1 OID, relation2 OID)
RETURNS BOOLEAN AS
$$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN (
        WITH
            a1 AS (select * from pg_attribute where attrelid = relation1 and attnum > 0),
            a2 AS (select * from pg_attribute where attrelid = relation2 and attnum > 0)
        SELECT a1.attname name1, a2.attname name2, a1.atttypid type1, a2.atttypid type2
        FROM a1
        FULL JOIN a2 ON a1.attnum = a2.attnum
    )
    LOOP
        IF rec.name1 IS NULL OR rec.name2 IS NULL OR rec.name1 != rec.name2 THEN
            RETURN False;
        END IF;
    END LOOP;

    RETURN True;
END
$$
LANGUAGE plpgsql;

/*
 * Check if regclass if date or timestamp
 */
CREATE OR REPLACE FUNCTION @extschema@.is_date(cls REGTYPE)
RETURNS BOOLEAN AS
$$
BEGIN
	RETURN cls IN ('timestamp'::regtype, 'timestamptz'::regtype, 'date'::regtype);
END
$$
LANGUAGE plpgsql;

/*
 * DDL trigger that deletes entry from pathman_config
 */
CREATE OR REPLACE FUNCTION @extschema@.pathman_ddl_trigger_func()
RETURNS event_trigger AS
$$
DECLARE
	obj record;
BEGIN
	FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects() as events
			   JOIN @extschema@.pathman_config as cfg ON cfg.relname = events.object_identity
	LOOP
		IF obj.object_type = 'table' THEN
			EXECUTE 'DELETE FROM @extschema@.pathman_config WHERE relname = $1'
			USING obj.object_identity;
		END IF;
	END LOOP;
END
$$
LANGUAGE plpgsql;

CREATE EVENT TRIGGER pathman_ddl_trigger
ON sql_drop
EXECUTE PROCEDURE @extschema@.pathman_ddl_trigger_func();

/*
 * Acquire partitions lock to prevent concurrent partitions creation
 */
CREATE OR REPLACE FUNCTION @extschema@.acquire_partitions_lock()
RETURNS VOID AS 'pg_pathman', 'acquire_partitions_lock' LANGUAGE C STRICT;

/*
 * Release partitions lock
 */
CREATE OR REPLACE FUNCTION @extschema@.release_partitions_lock()
RETURNS VOID AS 'pg_pathman', 'release_partitions_lock' LANGUAGE C STRICT;

/*
 * Drop trigger
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_triggers(IN relation REGCLASS)
RETURNS VOID AS
$$
DECLARE
	relname		TEXT;
	schema		TEXT;
	funcname	TEXT;
BEGIN
	SELECT * INTO schema, relname
	FROM @extschema@.get_plain_schema_and_relname(relation);

	funcname := schema || '.' || quote_ident(format('%s_update_trigger_func', relname));
	EXECUTE format('DROP FUNCTION IF EXISTS %s() CASCADE', funcname);
END
$$ LANGUAGE plpgsql;

/*
 * Drop partitions
 * If delete_data set to TRUE then partitions will be dropped with all the data
 */
CREATE OR REPLACE FUNCTION @extschema@.drop_partitions(
	relation REGCLASS
	, delete_data BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS
$$
DECLARE
	v_rec        RECORD;
	v_rows       INTEGER;
	v_part_count INTEGER := 0;
	v_relname    TEXT;
	conf_num_del INTEGER;
BEGIN
	v_relname := @extschema@.validate_relname(relation);

	/* Drop trigger first */
	PERFORM @extschema@.drop_triggers(relation);

	WITH config_num_deleted AS (DELETE FROM @extschema@.pathman_config
								WHERE relname::regclass = relation
								RETURNING *)
	SELECT count(*) from config_num_deleted INTO conf_num_del;

	IF conf_num_del = 0 THEN
		RAISE EXCEPTION 'table % has no partitions', relation::text;
	END IF;

	FOR v_rec IN (SELECT inhrelid::regclass::text AS tbl
				  FROM pg_inherits WHERE inhparent::regclass = relation)
	LOOP
		IF NOT delete_data THEN
			EXECUTE format('WITH part_data AS (DELETE FROM %s RETURNING *)
							INSERT INTO %s SELECT * FROM part_data'
						   , v_rec.tbl
						   , relation::text);
			GET DIAGNOSTICS v_rows = ROW_COUNT;
			RAISE NOTICE '% rows copied from %', v_rows, v_rec.tbl;
		END IF;
		EXECUTE format('DROP TABLE %s', v_rec.tbl);
		v_part_count := v_part_count + 1;
	END LOOP;

	/* Notify backend about changes */
	PERFORM @extschema@.on_remove_partitions(relation::oid);

	RETURN v_part_count;
END
$$ LANGUAGE plpgsql
SET pg_pathman.enable_partitionfilter = off;

/*
 * Returns hash function OID for specified type
 */
CREATE OR REPLACE FUNCTION @extschema@.get_type_hash_func(OID)
RETURNS OID AS 'pg_pathman', 'get_type_hash_func' LANGUAGE C STRICT;

/*
 * Calculates hash for integer value
 */
CREATE OR REPLACE FUNCTION @extschema@.get_hash(INTEGER, INTEGER)
RETURNS INTEGER AS 'pg_pathman', 'get_hash' LANGUAGE C STRICT;
