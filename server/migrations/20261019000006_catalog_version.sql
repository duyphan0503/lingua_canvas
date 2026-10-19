-- Separate global public-catalog revision from per-account progress cursors.
-- The epoch also prevents a recreated database from accepting a stale client revision.
CREATE TABLE public_catalog_revision (
 singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK(singleton),
 epoch TEXT NOT NULL DEFAULT md5(random()::text || clock_timestamp()::text),
 revision BIGINT NOT NULL DEFAULT 1
);
INSERT INTO public_catalog_revision(singleton) VALUES(TRUE);

CREATE FUNCTION advance_public_catalog_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP = 'INSERT' THEN
  IF NEW.category <> 'custom' THEN
   UPDATE public_catalog_revision SET revision = revision + 1 WHERE singleton;
  END IF;
 ELSIF TG_OP = 'DELETE' THEN
  IF OLD.category <> 'custom' THEN
   UPDATE public_catalog_revision SET revision = revision + 1 WHERE singleton;
  END IF;
 ELSE
  IF (OLD.category <> 'custom' OR NEW.category <> 'custom') AND OLD IS DISTINCT FROM NEW THEN
   UPDATE public_catalog_revision SET revision = revision + 1 WHERE singleton;
  END IF;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER lessons_public_catalog_revision
 AFTER INSERT OR UPDATE OR DELETE ON lessons
 FOR EACH ROW EXECUTE FUNCTION advance_public_catalog_revision();
