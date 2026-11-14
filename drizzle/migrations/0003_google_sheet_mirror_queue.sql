CREATE TABLE public.sheet_mirror_queue (
  id bigserial PRIMARY KEY,
  source_table text NOT NULL,
  row_id uuid NOT NULL,
  kind text NOT NULL DEFAULT 'row' CHECK (kind IN ('row', 'file')),
  queued_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0,
  last_error text NOT NULL DEFAULT '',
  UNIQUE (source_table, row_id, kind)
);
GRANT ALL ON public.sheet_mirror_queue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.sheet_mirror_queue_id_seq TO service_role;
ALTER TABLE public.sheet_mirror_queue ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.sheet_mirror_queue IS 'Rows and documents waiting to be copied to the Google Sheet / Drive; server-only.';

ALTER TABLE public.registration_applications ADD COLUMN IF NOT EXISTS drive_file_url text;

CREATE OR REPLACE FUNCTION public.queue_sheet_mirror()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.sheet_mirror_queue (source_table, row_id, kind)
  VALUES (TG_TABLE_NAME, NEW.id, 'row')
  ON CONFLICT (source_table, row_id, kind) DO UPDATE SET queued_at = now(), attempts = 0, last_error = '';
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.queue_drive_document()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.document_path IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.document_path IS DISTINCT FROM OLD.document_path) THEN
    INSERT INTO public.sheet_mirror_queue (source_table, row_id, kind)
    VALUES (TG_TABLE_NAME, NEW.id, 'file')
    ON CONFLICT (source_table, row_id, kind) DO UPDATE SET queued_at = now(), attempts = 0, last_error = '';
  END IF;
  RETURN NEW;
END $$;

REVOKE EXECUTE ON FUNCTION public.queue_sheet_mirror() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.queue_drive_document() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER mirror_contact_submissions AFTER INSERT OR UPDATE ON public.contact_submissions FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_registration_applications AFTER INSERT OR UPDATE ON public.registration_applications FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_registration_documents AFTER INSERT OR UPDATE OF document_path ON public.registration_applications FOR EACH ROW EXECUTE FUNCTION public.queue_drive_document();
CREATE TRIGGER mirror_programme_applications AFTER INSERT OR UPDATE ON public.programme_applications FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_foundation_submissions AFTER INSERT OR UPDATE ON public.foundation_submissions FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_young_innovators_registrations AFTER INSERT OR UPDATE ON public.young_innovators_registrations FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_prototype_submissions AFTER INSERT OR UPDATE ON public.prototype_submissions FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_crm_leads AFTER INSERT OR UPDATE ON public.crm_leads FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();
CREATE TRIGGER mirror_programme_payments AFTER INSERT OR UPDATE ON public.programme_payments FOR EACH ROW EXECUTE FUNCTION public.queue_sheet_mirror();

INSERT INTO public.sheet_mirror_queue (source_table, row_id, kind)
SELECT t.source_table, t.id, 'row' FROM (
  SELECT 'contact_submissions' AS source_table, id FROM public.contact_submissions
  UNION ALL SELECT 'registration_applications', id FROM public.registration_applications
  UNION ALL SELECT 'programme_applications', id FROM public.programme_applications
  UNION ALL SELECT 'foundation_submissions', id FROM public.foundation_submissions
  UNION ALL SELECT 'young_innovators_registrations', id FROM public.young_innovators_registrations
  UNION ALL SELECT 'prototype_submissions', id FROM public.prototype_submissions
  UNION ALL SELECT 'crm_leads', id FROM public.crm_leads
  UNION ALL SELECT 'programme_payments', id FROM public.programme_payments
) t
ON CONFLICT DO NOTHING;

INSERT INTO public.sheet_mirror_queue (source_table, row_id, kind)
SELECT 'registration_applications', id, 'file' FROM public.registration_applications WHERE document_path IS NOT NULL
ON CONFLICT DO NOTHING;