-- Acknowledgement numbers: YYMMDD + 2-digit state + 2-digit form + 5-digit serial, one counter per form.
CREATE TABLE public.ack_form_counters (
  form_code text PRIMARY KEY CHECK (form_code ~ '^\d{2}$'),
  form_name text NOT NULL,
  last_serial integer NOT NULL DEFAULT 0 CHECK (last_serial BETWEEN 0 AND 99999)
);
GRANT ALL ON public.ack_form_counters TO service_role;
ALTER TABLE public.ack_form_counters ENABLE ROW LEVEL SECURITY;
INSERT INTO public.ack_form_counters (form_code, form_name) VALUES
  ('01', 'Scholarship (Education Support)'), ('02', 'Young Innovators'), ('03', 'Funding Programme'),
  ('04', 'Foundation'), ('05', 'Startup / Investor / Mentor / Business registration'), ('06', 'Enquiry');

CREATE OR REPLACE FUNCTION public.ack_state_code(_state text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT coalesce(lpad(array_position(ARRAY['andhra pradesh','arunachal pradesh','assam','bihar','chhattisgarh','goa','gujarat','haryana','himachal pradesh','jharkhand',
    'karnataka','kerala','madhya pradesh','maharashtra','manipur','meghalaya','mizoram','nagaland','odisha','punjab',
    'rajasthan','sikkim','tamil nadu','telangana','tripura','uttar pradesh','uttarakhand','west bengal',
    'andaman and nicobar islands','chandigarh','dadra and nagar haveli and daman and diu','delhi','jammu and kashmir','ladakh','lakshadweep','puducherry'],
    lower(btrim(coalesce(_state, ''))))::text, 2, '0'), '00')
$$;

CREATE OR REPLACE FUNCTION public.issue_ack_number(_form text, _state text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _serial integer;
BEGIN
  UPDATE public.ack_form_counters SET last_serial = CASE WHEN last_serial >= 99999 THEN 1 ELSE last_serial + 1 END
    WHERE form_code = _form RETURNING last_serial INTO _serial;
  IF _serial IS NULL THEN RAISE EXCEPTION 'Unknown form code for acknowledgement number'; END IF;
  RETURN to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYMMDD') || public.ack_state_code(_state) || _form || lpad(_serial::text, 5, '0');
END $$;
REVOKE EXECUTE ON FUNCTION public.issue_ack_number(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_ack_number(text, text) TO service_role;

-- Scholarship: a temporary Registration ID (R...) until the payment ID is shared, then the real acknowledgement number.
ALTER TABLE public.education_support_registrations ADD COLUMN registration_id text;
CREATE UNIQUE INDEX education_support_registration_id_unique ON public.education_support_registrations (registration_id) WHERE registration_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.assign_education_ack_number()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _temp text; _paid boolean;
BEGIN
  _paid := NEW.payment_status IN ('reference_submitted', 'paid');
  IF TG_OP = 'INSERT' THEN
    IF coalesce(NEW.ack_number, '') = '' THEN
      IF _paid THEN NEW.ack_number := public.issue_ack_number('01', NEW.state); RETURN NEW; END IF;
      LOOP
        _temp := 'R' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYMMDD') || public.ack_state_code(NEW.state)
          || lpad(floor(random() * 10000000)::int::text, 7, '0');
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.education_support_registrations WHERE ack_number = _temp OR registration_id = _temp);
      END LOOP;
      NEW.ack_number := _temp;
      RETURN NEW;
    END IF;
  END IF;
  -- A temporary or backup number becomes a real acknowledgement number once the payment ID is shared.
  IF _paid AND NEW.ack_number ~ '^[A-Z]' THEN
    NEW.registration_id := NEW.ack_number;
    NEW.ack_number := public.issue_ack_number('01', NEW.state);
    IF TG_OP = 'UPDATE' THEN
      UPDATE public.crm_customers SET acknowledgement = NEW.ack_number WHERE acknowledgement = NEW.registration_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.assign_education_ack_number() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER assign_education_ack_on_payment BEFORE UPDATE OF payment_status ON public.education_support_registrations
  FOR EACH ROW EXECUTE FUNCTION public.assign_education_ack_number();

-- Other forms: number issued immediately on submission.
ALTER TABLE public.young_innovators_registrations ALTER COLUMN application_code SET DEFAULT '';
ALTER TABLE public.registration_applications ALTER COLUMN application_code SET DEFAULT '';
ALTER TABLE public.programme_applications ALTER COLUMN application_code SET DEFAULT '';
ALTER TABLE public.foundation_submissions ADD COLUMN ack_number text NOT NULL DEFAULT '';
ALTER TABLE public.contact_submissions ADD COLUMN ack_number text NOT NULL DEFAULT '';

CREATE OR REPLACE FUNCTION public.assign_form_ack_number()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _form text := TG_ARGV[0]; _state text;
BEGIN
  IF TG_TABLE_NAME IN ('foundation_submissions', 'contact_submissions') THEN
    IF coalesce(NEW.ack_number, '') <> '' THEN RETURN NEW; END IF;
  ELSIF coalesce(NEW.application_code, '') <> '' THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME IN ('registration_applications', 'programme_applications', 'foundation_submissions') THEN
    _state := NEW.details->>'state';
  END IF;
  IF TG_TABLE_NAME IN ('foundation_submissions', 'contact_submissions') THEN
    NEW.ack_number := public.issue_ack_number(_form, _state);
  ELSE
    NEW.application_code := public.issue_ack_number(_form, _state);
  END IF;
  RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION public.assign_form_ack_number() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER assign_ack BEFORE INSERT ON public.young_innovators_registrations FOR EACH ROW EXECUTE FUNCTION public.assign_form_ack_number('02');
CREATE TRIGGER assign_ack BEFORE INSERT ON public.programme_applications FOR EACH ROW EXECUTE FUNCTION public.assign_form_ack_number('03');
CREATE TRIGGER assign_ack BEFORE INSERT ON public.foundation_submissions FOR EACH ROW EXECUTE FUNCTION public.assign_form_ack_number('04');
CREATE TRIGGER assign_ack BEFORE INSERT ON public.registration_applications FOR EACH ROW EXECUTE FUNCTION public.assign_form_ack_number('05');
CREATE TRIGGER assign_ack BEFORE INSERT ON public.contact_submissions FOR EACH ROW EXECUTE FUNCTION public.assign_form_ack_number('06');

COMMENT ON SEQUENCE public.education_ack_serial IS 'DEPRECATED: replaced by ack_form_counters (form 01)';
COMMENT ON TABLE public.education_district_codes IS 'DEPRECATED: acknowledgement numbers now use a form code instead of a district code';