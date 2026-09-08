SET local check_function_bodies = off;

CREATE TABLE "memory"."context_version" (
  "singleton" boolean NOT NULL DEFAULT true,
  "version"   bigint  NOT NULL DEFAULT 0,
  CONSTRAINT "context_version_pkey" PRIMARY KEY (singleton),
  CONSTRAINT "context_version_singleton_check" CHECK (singleton)
);

INSERT INTO memory.context_version(singleton,version) VALUES (true,0);

ALTER TABLE "memory"."context_version"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION memory.invalidate_context()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  update memory.context_version set version=version+1 where singleton;
  return null;
end $function$;

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.assertions
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.attributes
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.entities
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.plans
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.questions
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.relations
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.relationships
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

CREATE TRIGGER context_changed
  AFTER INSERT OR DELETE OR UPDATE OR TRUNCATE ON memory.rules
  FOR EACH STATEMENT
  EXECUTE FUNCTION memory.invalidate_context();

REVOKE ALL ON FUNCTION "memory"."invalidate_context"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "memory"."invalidate_context"() TO "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "memory"."context_version" TO "postgres", "service_role";
