-- ===== Admin bootstrap =====
CREATE OR REPLACE FUNCTION public.first_admin_setup_status()
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _first uuid; _confirmed timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RETURN 'closed'; END IF;
  IF EXISTS (SELECT 1 FROM public.user_roles WHERE role = 'admin') THEN RETURN 'closed'; END IF;
  SELECT u.id INTO _first FROM auth.users u ORDER BY u.created_at, u.id LIMIT 1;
  IF _first IS DISTINCT FROM auth.uid() THEN RETURN 'not_first_account'; END IF;
  SELECT u.email_confirmed_at INTO _confirmed FROM auth.users u WHERE u.id = auth.uid();
  RETURN CASE WHEN _confirmed IS NULL THEN 'unverified' ELSE 'eligible' END;
END $$;

CREATE OR REPLACE FUNCTION public.claim_first_admin()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('public.claim_first_admin'));
  IF public.first_admin_setup_status() <> 'eligible' THEN
    RAISE EXCEPTION 'First-admin setup is not available for this account' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.user_roles (user_id, role) VALUES (auth.uid(), 'admin') ON CONFLICT DO NOTHING;
  RETURN true;
END $$;

-- ===== Employee ID verification =====
CREATE OR REPLACE FUNCTION public.admin_save_employee(_employee_id text, _code text, _full_name text, _photo_url text,
  _designation text, _department text, _status text, _valid_until text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE _id text := trim(coalesce(_employee_id, ''));
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF _id = '' OR trim(coalesce(_full_name, '')) = '' THEN RAISE EXCEPTION 'Employee ID and name are required'; END IF;
  IF coalesce(_status, 'active') NOT IN ('active', 'inactive') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  IF EXISTS (SELECT 1 FROM public.employees e WHERE upper(e.employee_id) = upper(_id)) THEN
    UPDATE public.employees e SET
      full_name = trim(_full_name),
      photo_url = nullif(trim(coalesce(_photo_url, '')), ''),
      designation = coalesce(_designation, ''),
      department = coalesce(_department, ''),
      status = coalesce(_status, 'active'),
      valid_until = nullif(coalesce(_valid_until, ''), '')::date,
      code_hash = CASE WHEN coalesce(_code, '') <> '' THEN extensions.crypt(_code, extensions.gen_salt('bf', 10)) ELSE e.code_hash END,
      updated_at = now()
    WHERE upper(e.employee_id) = upper(_id);
  ELSE
    IF length(coalesce(_code, '')) < 6 THEN RAISE EXCEPTION 'A verification code of at least 6 characters is required'; END IF;
    INSERT INTO public.employees (employee_id, code_hash, full_name, photo_url, designation, department, status, valid_until)
    VALUES (_id, extensions.crypt(_code, extensions.gen_salt('bf', 10)), trim(_full_name), nullif(trim(coalesce(_photo_url, '')), ''),
      coalesce(_designation, ''), coalesce(_department, ''), coalesce(_status, 'active'), nullif(coalesce(_valid_until, ''), '')::date);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.verify_employee(_employee_id text, _code text)
RETURNS TABLE (employee_id text, full_name text, photo_url text, designation text, department text, status text, valid_until date)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
#variable_conflict use_column
DECLARE _id text := upper(trim(coalesce(_employee_id, ''))); _e public.employees%ROWTYPE; _ok boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.employee_verification_attempts a
      WHERE a.employee_id = _id AND NOT a.success AND a.created_at > now() - interval '15 minutes') >= 5 THEN
    RAISE EXCEPTION 'too_many_attempts';
  END IF;
  SELECT * INTO _e FROM public.employees e WHERE upper(e.employee_id) = _id;
  IF FOUND AND coalesce(_code, '') <> '' THEN _ok := _e.code_hash = extensions.crypt(_code, _e.code_hash); END IF;
  INSERT INTO public.employee_verification_attempts (employee_id, success) VALUES (_id, _ok);
  IF random() < 0.01 THEN DELETE FROM public.employee_verification_attempts a WHERE a.created_at < now() - interval '7 days'; END IF;
  IF _ok THEN
    RETURN QUERY SELECT _e.employee_id, _e.full_name, _e.photo_url, _e.designation, _e.department, _e.status, _e.valid_until;
  END IF;
END $$;

-- ===== Durable form limiter (server only) =====
CREATE OR REPLACE FUNCTION public.consume_form_submission_limit(_key_hash text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _attempts integer;
BEGIN
  IF _key_hash IS NULL OR length(_key_hash) < 16 THEN RAISE EXCEPTION 'Invalid limiter key'; END IF;
  INSERT INTO public.form_submission_limits AS l (key_hash, window_started_at, attempts) VALUES (_key_hash, now(), 1)
  ON CONFLICT (key_hash) DO UPDATE SET
    attempts = CASE WHEN l.window_started_at < now() - interval '15 minutes' THEN 1 ELSE l.attempts + 1 END,
    window_started_at = CASE WHEN l.window_started_at < now() - interval '15 minutes' THEN now() ELSE l.window_started_at END
  RETURNING attempts INTO _attempts;
  IF random() < 0.01 THEN DELETE FROM public.form_submission_limits WHERE window_started_at < now() - interval '1 day'; END IF;
  RETURN _attempts <= 5;
END $$;

-- ===== Admin CSV import (invoker: admin RLS applies) =====
CREATE OR REPLACE FUNCTION public.admin_import_records(_table text, _rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  _allowed constant text[] := ARRAY['contact_submissions','registration_applications','employees','people_profiles',
    'customer_reports','country_logos','country_programme_fees','prototype_submissions','young_innovators_registrations'];
  _row jsonb; _cols text; _bad text; _n integer; _inserted integer := 0; _skipped integer := 0;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF _table IS NULL OR NOT (_table = ANY (_allowed)) THEN RAISE EXCEPTION 'This table cannot be imported'; END IF;
  IF jsonb_typeof(_rows) <> 'array' OR jsonb_array_length(_rows) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Provide 1 to 1000 rows'; END IF;
  FOR _row IN SELECT value FROM jsonb_array_elements(_rows) LOOP
    IF jsonb_typeof(_row) <> 'object' OR _row = '{}'::jsonb THEN RAISE EXCEPTION 'Each row must be a non-empty object'; END IF;
    SELECT k INTO _bad FROM jsonb_object_keys(_row) AS k
      WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = format('public.%I', _table)::regclass
                        AND a.attname = k AND a.attnum > 0 AND NOT a.attisdropped) LIMIT 1;
    IF _bad IS NOT NULL THEN RAISE EXCEPTION 'Unknown column %', _bad; END IF;
    SELECT string_agg(format('%I', k), ', ') INTO _cols FROM jsonb_object_keys(_row) AS k;
    EXECUTE format('INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) ON CONFLICT DO NOTHING',
      _table, _cols, _cols, _table) USING _row;
    GET DIAGNOSTICS _n = ROW_COUNT;
    IF _n > 0 THEN _inserted := _inserted + 1; ELSE _skipped := _skipped + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('inserted', _inserted, 'skipped', _skipped);
END $$;

-- ===== Setup diagnostics (catalog metadata only) =====
CREATE OR REPLACE FUNCTION public.admin_setup_metadata()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  RETURN jsonb_build_object(
    'tables', coalesce((
      SELECT jsonb_agg(jsonb_build_object('name', c.relname, 'rls', c.relrowsecurity, 'columns', (
        SELECT coalesce(jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, NULL), 'nullable', NOT a.attnotnull) ORDER BY a.attnum), '[]'::jsonb)
        FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)) ORDER BY c.relname)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')), '[]'::jsonb),
    'functions', coalesce((SELECT jsonb_agg(DISTINCT p.proname) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'), '[]'::jsonb),
    'triggers', coalesce((SELECT jsonb_agg(DISTINCT t.tgname) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
      JOIN pg_namespace n ON n.oid = p.pronamespace WHERE NOT t.tgisinternal AND n.nspname = 'public'), '[]'::jsonb)
  );
END $$;

-- ===== Account profiles =====
CREATE OR REPLACE FUNCTION public.create_account_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  BEGIN
    INSERT INTO public.profiles (id, display_name)
    VALUES (NEW.id, left(coalesce(nullif(NEW.raw_user_meta_data->>'display_name', ''), nullif(NEW.raw_user_meta_data->>'full_name', ''),
      split_part(coalesce(NEW.email, ''), '@', 1)), 100))
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Account profile not created: %', SQLERRM;
  END;
  RETURN NEW;
END $$;
CREATE TRIGGER create_account_profile AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.create_account_profile();

-- ===== People profiles published from approved applications =====
CREATE OR REPLACE FUNCTION public.people_profile_safe_text(_value text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT left(btrim(regexp_replace(regexp_replace(coalesce(_value, ''),
    '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '', 'g'),
    '\+?[0-9][0-9 ().-]{7,}[0-9]', '', 'g')), 600)
$$;

CREATE OR REPLACE FUNCTION public.json_text_list(_value jsonb)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = public AS $$
  SELECT CASE jsonb_typeof(_value)
    WHEN 'array' THEN ARRAY(SELECT public.people_profile_safe_text(x) FROM jsonb_array_elements_text(_value) x WHERE btrim(x) <> '' LIMIT 12)
    WHEN 'string' THEN ARRAY(SELECT public.people_profile_safe_text(x) FROM unnest(string_to_array(_value #>> '{}', ',')) x WHERE btrim(x) <> '' LIMIT 12)
    ELSE '{}'::text[] END
$$;

CREATE OR REPLACE FUNCTION public.sync_approved_application_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _d jsonb := coalesce(NEW.details, '{}'::jsonb);
  _group text; _name text; _role text; _location text; _focus text[]; _summary text; _slug text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'approved' THEN
    DELETE FROM public.people_profiles WHERE source_application_id = NEW.id;
    RETURN NEW;
  END IF;
  _group := CASE NEW.category WHEN 'investor' THEN 'investors' WHEN 'mentor' THEN 'mentors' WHEN 'startup' THEN 'startups' WHEN 'business' THEN 'businesses' END;
  IF _group IS NULL THEN RETURN NEW; END IF;
  _name := public.people_profile_safe_text(CASE NEW.category
    WHEN 'startup' THEN coalesce(nullif(_d->>'startupName', ''), NEW.full_name)
    WHEN 'business' THEN coalesce(nullif(_d->>'businessName', ''), NEW.full_name)
    ELSE NEW.full_name END);
  _role := public.people_profile_safe_text(CASE NEW.category
    WHEN 'mentor' THEN concat_ws(', ', nullif(_d->>'designation', ''), nullif(_d->>'organization', ''))
    WHEN 'investor' THEN coalesce(_d->>'investmentFocus', '')
    WHEN 'startup' THEN concat_ws(' · ', nullif(_d->>'startupStage', ''), nullif(_d->>'industry', ''))
    ELSE coalesce(_d->>'industry', '') END);
  _location := public.people_profile_safe_text(coalesce(nullif(_d->>'location', ''), nullif(_d->>'headquarter', ''), nullif(_d->>'city', ''), ''));
  _focus := public.json_text_list(coalesce(_d->'supportAreas', _d->'expertise', _d->'interests', _d->'mentorAudience'));
  _summary := public.people_profile_safe_text(coalesce(nullif(_d->>'product', ''), nullif(_d->>'mentorAreas', ''),
    nullif(_d->>'investmentThesis', ''), nullif(_d->>'products', ''), ''));
  _slug := btrim(lower(regexp_replace(coalesce(nullif(_name, ''), 'profile'), '[^a-zA-Z0-9]+', '-', 'g')), '-')
    || '-' || left(replace(NEW.id::text, '-', ''), 6);
  INSERT INTO public.people_profiles (person_group, slug, name, role, location, focus, summary, source_application_id)
  VALUES (_group, _slug, coalesce(nullif(_name, ''), 'Profile'), _role, _location, coalesce(_focus, '{}'), _summary, NEW.id)
  ON CONFLICT (source_application_id) DO UPDATE SET
    person_group = EXCLUDED.person_group, name = EXCLUDED.name, role = EXCLUDED.role,
    location = EXCLUDED.location, focus = EXCLUDED.focus, summary = EXCLUDED.summary;
  RETURN NEW;
END $$;
CREATE TRIGGER sync_approved_application_profile AFTER INSERT OR UPDATE OF status, category, full_name, details
  ON public.registration_applications FOR EACH ROW EXECUTE FUNCTION public.sync_approved_application_profile();

-- ===== Education Support acknowledgement numbers and approval guard =====
CREATE SEQUENCE public.education_ack_serial MINVALUE 1 MAXVALUE 99999 CYCLE;
GRANT ALL ON SEQUENCE public.education_ack_serial TO service_role;

CREATE OR REPLACE FUNCTION public.assign_education_ack_number()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _states constant text[] := ARRAY['Andhra Pradesh','Arunachal Pradesh','Assam','Bihar','Chhattisgarh','Goa','Gujarat','Haryana','Himachal Pradesh','Jharkhand',
    'Karnataka','Kerala','Madhya Pradesh','Maharashtra','Manipur','Meghalaya','Mizoram','Nagaland','Odisha','Punjab',
    'Rajasthan','Sikkim','Tamil Nadu','Telangana','Tripura','Uttar Pradesh','Uttarakhand','West Bengal',
    'Andaman and Nicobar Islands','Chandigarh','Dadra and Nagar Haveli and Daman and Diu','Delhi','Jammu and Kashmir','Ladakh','Lakshadweep','Puducherry'];
  _idx integer; _state_code text; _key text; _dcode integer;
BEGIN
  IF NEW.ack_number IS NOT NULL AND NEW.ack_number <> '' THEN RETURN NEW; END IF;
  _idx := array_position(_states, NEW.state);
  IF _idx IS NULL THEN RAISE EXCEPTION 'Unknown state for acknowledgement number'; END IF;
  _state_code := lpad(_idx::text, 2, '0');
  _key := lower(regexp_replace(btrim(coalesce(NEW.district, '')), '\s+', ' ', 'g'));
  IF _key = '' THEN _key := 'unknown'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('education_district_codes:' || _state_code));
  SELECT code INTO _dcode FROM public.education_district_codes WHERE state_code = _state_code AND district_key = _key;
  IF NOT FOUND THEN
    SELECT least(coalesce(max(code), 0) + 1, 99) INTO _dcode FROM public.education_district_codes WHERE state_code = _state_code;
    INSERT INTO public.education_district_codes (state_code, district_key, district_name, code)
    VALUES (_state_code, _key, coalesce(nullif(btrim(NEW.district), ''), 'Unknown'), _dcode);
  END IF;
  NEW.ack_number := to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYMMDD') || _state_code || lpad(_dcode::text, 2, '0')
    || lpad(nextval('public.education_ack_serial')::text, 5, '0');
  RETURN NEW;
END $$;
CREATE TRIGGER assign_education_ack BEFORE INSERT ON public.education_support_registrations
  FOR EACH ROW EXECUTE FUNCTION public.assign_education_ack_number();

CREATE OR REPLACE FUNCTION public.guard_education_approval()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- A new mismatch check needs a fresh human confirmation.
    IF NEW.flags_checked_at IS DISTINCT FROM OLD.flags_checked_at AND NEW.flags_confirmed_at IS NOT DISTINCT FROM OLD.flags_confirmed_at THEN
      NEW.flags_confirmed_at := NULL; NEW.flags_confirmed_by := NULL;
    END IF;
    IF NEW.flags_confirmed_at IS NOT NULL AND NEW.flags_confirmed_at IS DISTINCT FROM OLD.flags_confirmed_at THEN
      IF NEW.flags_checked_at IS NULL THEN RAISE EXCEPTION 'Run the mismatch check first' USING ERRCODE = '23514'; END IF;
      NEW.flags_confirmed_at := now(); NEW.flags_confirmed_by := auth.uid();
    END IF;
    NEW.updated_at := now();
  END IF;
  IF NEW.approval_status = 'approved' AND (TG_OP = 'INSERT' OR OLD.approval_status IS DISTINCT FROM 'approved') THEN
    IF NEW.payment_status <> 'paid' OR NEW.flags_checked_at IS NULL OR NEW.flags_confirmed_at IS NULL THEN
      RAISE EXCEPTION 'Approval needs confirmed payment and a confirmed mismatch check' USING ERRCODE = '23514';
    END IF;
    NEW.approved_at := now(); NEW.approved_by := auth.uid();
  ELSIF NEW.approval_status IS DISTINCT FROM 'approved' THEN
    NEW.approved_at := NULL; NEW.approved_by := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_education_approval BEFORE INSERT OR UPDATE ON public.education_support_registrations
  FOR EACH ROW EXECUTE FUNCTION public.guard_education_approval();

-- ===== CRM =====
CREATE OR REPLACE FUNCTION public.crm_owner_for_code(_code text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _c text := upper(btrim(coalesce(_code, ''))); _owner uuid;
BEGIN
  IF _c = '' THEN RETURN NULL; END IF;
  SELECT p.user_id INTO _owner FROM public.crm_employee_profiles p
    JOIN public.crm_memberships m ON m.user_id = p.user_id AND m.active
    WHERE upper(p.employee_code) = _c LIMIT 1;
  IF _owner IS NULL THEN
    SELECT s.user_id INTO _owner FROM public.education_staff_access s
      JOIN public.crm_memberships m ON m.user_id = s.user_id AND m.active
      WHERE s.active AND upper(s.referral_code) = _c LIMIT 1;
  END IF;
  RETURN _owner;
END $$;

CREATE OR REPLACE FUNCTION public.crm_route_submission(_source text, _source_id uuid, _full_name text, _email text, _phone text,
  _company text, _title text, _code text, _acknowledgement text, _amount numeric, _owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _lead uuid; _customer uuid; _o uuid;
BEGIN
  SELECT id INTO _lead FROM public.crm_leads WHERE source = _source AND source_id = _source_id;
  IF FOUND THEN RETURN _lead; END IF;
  _o := coalesce(_owner, public.crm_owner_for_code(_code));
  IF btrim(coalesce(_email, '')) <> '' THEN
    SELECT id INTO _customer FROM public.crm_customers WHERE lower(email) = lower(btrim(_email)) ORDER BY created_at LIMIT 1;
  END IF;
  IF _customer IS NULL THEN
    INSERT INTO public.crm_customers (full_name, email, phone, company, acknowledgement, owner_id)
    VALUES (left(coalesce(nullif(btrim(_full_name), ''), 'Website visitor'), 200), left(btrim(coalesce(_email, '')), 320),
      left(btrim(coalesce(_phone, '')), 40), left(coalesce(_company, ''), 150), nullif(left(coalesce(_acknowledgement, ''), 60), ''), _o)
    RETURNING id INTO _customer;
  ELSIF _o IS NOT NULL THEN
    UPDATE public.crm_customers SET owner_id = _o WHERE id = _customer AND owner_id IS NULL;
  END IF;
  INSERT INTO public.crm_leads (customer_id, title, amount, source, source_id, owner_id, referral_code)
  VALUES (_customer, left(coalesce(nullif(btrim(_title), ''), 'Website lead'), 200), coalesce(_amount, 0), _source, _source_id, _o,
    nullif(upper(btrim(coalesce(_code, ''))), ''))
  RETURNING id INTO _lead;
  RETURN _lead;
END $$;

-- Maps a website submission (contact fields only; never bank/KYC) to a CRM lead.
CREATE OR REPLACE FUNCTION public.crm_submission_lead(_kind text, r jsonb, _owner uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN CASE _kind
    WHEN 'enquiry' THEN public.crm_route_submission('enquiry', (r->>'id')::uuid, r->>'name', r->>'email', r->>'phone', '',
      'Enquiry: ' || coalesce(r->>'service', ''), r->>'coordinator_code', NULL, 0, _owner)
    WHEN 'registration' THEN public.crm_route_submission('registration', (r->>'id')::uuid, r->>'full_name', r->>'email', r->>'phone',
      coalesce(r->'details'->>'startupName', r->'details'->>'organization', r->'details'->>'businessName', ''),
      'Registration: ' || coalesce(r->>'category', ''), r->>'coordinator_code', r->>'application_code', 0, _owner)
    WHEN 'education' THEN public.crm_route_submission('education', (r->>'id')::uuid, r->>'student_name', r->>'email', r->>'mobile',
      coalesce(r->>'institution_name', ''), 'Education Support: ' || coalesce(r->>'application_type', ''), r->>'coordinator_code',
      r->>'ack_number', coalesce((r->>'registration_fee')::numeric, 0), _owner)
    WHEN 'foundation' THEN public.crm_route_submission('foundation', (r->>'id')::uuid, r->>'full_name', r->>'email', r->>'phone', '',
      'Foundation: ' || coalesce(r->>'kind', ''), r->>'coordinator_code', NULL, 0, _owner)
    WHEN 'young_innovators' THEN public.crm_route_submission('young_innovators', (r->>'id')::uuid, r->>'guardian_name', r->>'guardian_email',
      r->>'guardian_phone', '', 'Young Innovators: Class ' || coalesce(r->>'school_class', ''), r->>'coordinator_code', r->>'application_code',
      coalesce((r->>'fee_amount')::numeric, 0), _owner)
    WHEN 'programme' THEN public.crm_route_submission('programme', (r->>'id')::uuid, r->>'full_name', r->>'email', r->>'phone', '',
      'Programme: ' || coalesce(r->>'programme', ''), r->>'coordinator_code', r->>'application_code',
      coalesce((r->>'amount_paise')::numeric, 0) / 100, _owner)
    ELSE NULL END;
END $$;

CREATE OR REPLACE FUNCTION public.crm_intake_submission()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  BEGIN
    PERFORM public.crm_submission_lead(CASE TG_TABLE_NAME
      WHEN 'contact_submissions' THEN 'enquiry'
      WHEN 'registration_applications' THEN 'registration'
      WHEN 'education_support_registrations' THEN 'education'
      WHEN 'foundation_submissions' THEN 'foundation'
      WHEN 'young_innovators_registrations' THEN 'young_innovators'
      WHEN 'programme_applications' THEN 'programme' END, to_jsonb(NEW), NULL);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'CRM intake skipped for %: %', TG_TABLE_NAME, SQLERRM;
  END;
  RETURN NEW;
END $$;
CREATE TRIGGER crm_intake AFTER INSERT ON public.contact_submissions FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();
CREATE TRIGGER crm_intake AFTER INSERT ON public.registration_applications FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();
CREATE TRIGGER crm_intake AFTER INSERT ON public.education_support_registrations FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();
CREATE TRIGGER crm_intake AFTER INSERT ON public.foundation_submissions FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();
CREATE TRIGGER crm_intake AFTER INSERT ON public.young_innovators_registrations FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();
CREATE TRIGGER crm_intake AFTER INSERT ON public.programme_applications FOR EACH ROW EXECUTE FUNCTION public.crm_intake_submission();

CREATE OR REPLACE FUNCTION public.crm_import_submission(_id uuid, _kind text, _owner uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _row jsonb;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF _owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.crm_memberships WHERE user_id = _owner AND active) THEN
    RAISE EXCEPTION 'Owner must be an active CRM employee';
  END IF;
  _row := CASE _kind
    WHEN 'enquiry' THEN (SELECT to_jsonb(t) FROM public.contact_submissions t WHERE t.id = _id)
    WHEN 'registration' THEN (SELECT to_jsonb(t) FROM public.registration_applications t WHERE t.id = _id)
    WHEN 'education' THEN (SELECT to_jsonb(t) FROM public.education_support_registrations t WHERE t.id = _id)
    WHEN 'foundation' THEN (SELECT to_jsonb(t) FROM public.foundation_submissions t WHERE t.id = _id)
    WHEN 'young_innovators' THEN (SELECT to_jsonb(t) FROM public.young_innovators_registrations t WHERE t.id = _id)
    WHEN 'programme' THEN (SELECT to_jsonb(t) FROM public.programme_applications t WHERE t.id = _id)
  END;
  IF _row IS NULL THEN RAISE EXCEPTION 'Submission not found'; END IF;
  PERFORM public.crm_submission_lead(_kind, _row, _owner);
END $$;

-- Invoker: row security decides whether the caller may create for that owner.
CREATE OR REPLACE FUNCTION public.crm_create_lead(_input jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE _owner uuid := (_input->>'ownerId')::uuid; _customer uuid; _lead uuid; _role text := public.crm_role();
BEGIN
  IF _role IS NULL OR _role = 'support' THEN RAISE EXCEPTION 'Sales access required' USING ERRCODE = '42501'; END IF;
  IF NOT public.has_role(_owner, 'admin') AND NOT EXISTS (SELECT 1 FROM public.crm_memberships WHERE user_id = _owner AND active) THEN
    RAISE EXCEPTION 'Assigned employee is not active';
  END IF;
  INSERT INTO public.crm_customers (full_name, email, phone, company, acknowledgement, owner_id)
  VALUES (btrim(_input->>'fullName'), btrim(coalesce(_input->>'email', '')), btrim(coalesce(_input->>'phone', '')),
    btrim(coalesce(_input->>'company', '')), nullif(btrim(coalesce(_input->>'acknowledgement', '')), ''), _owner)
  RETURNING id INTO _customer;
  INSERT INTO public.crm_leads (customer_id, title, amount, owner_id, next_follow_up, source)
  VALUES (_customer, btrim(_input->>'title'), coalesce((_input->>'amount')::numeric, 0), _owner,
    nullif(coalesce(_input->>'followUp', ''), '')::date, 'manual')
  RETURNING id INTO _lead;
  RETURN _lead;
END $$;

CREATE OR REPLACE FUNCTION public.crm_assign_lead(_lead uuid, _owner uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _role text := public.crm_role(); _current uuid; _customer uuid;
BEGIN
  IF _role IS NULL OR _role NOT IN ('admin', 'BDM') THEN RAISE EXCEPTION 'Only an admin or BDM can reassign leads' USING ERRCODE = '42501'; END IF;
  SELECT owner_id, customer_id INTO _current, _customer FROM public.crm_leads WHERE id = _lead FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found'; END IF;
  IF _role = 'BDM' AND (NOT public.crm_can_access(_current) OR _owner IS NULL OR NOT public.crm_can_access(_owner)) THEN
    RAISE EXCEPTION 'Lead and employee must be in your team' USING ERRCODE = '42501';
  END IF;
  IF _owner IS NOT NULL AND NOT public.has_role(_owner, 'admin')
     AND NOT EXISTS (SELECT 1 FROM public.crm_memberships WHERE user_id = _owner AND active) THEN
    RAISE EXCEPTION 'Employee is not active';
  END IF;
  UPDATE public.crm_leads SET owner_id = _owner, updated_at = now() WHERE id = _lead;
  UPDATE public.crm_customers SET owner_id = _owner WHERE id = _customer AND (owner_id IS NULL OR owner_id IS NOT DISTINCT FROM _current);
END $$;

CREATE OR REPLACE FUNCTION public.crm_onboard_member(_user_id uuid, _input jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _role text := _input->>'role'; _manager uuid := nullif(coalesce(_input->>'managerId', ''), '')::uuid;
  _code text := upper(btrim(coalesce(_input->>'employeeCode', '')));
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  IF _user_id IS NULL OR _role IS NULL OR _role NOT IN ('sales', 'support', 'BDE', 'BDM') THEN RAISE EXCEPTION 'Invalid role'; END IF;
  IF _code = '' OR btrim(coalesce(_input->>'fullName', '')) = '' THEN RAISE EXCEPTION 'Employee code and name are required'; END IF;
  IF _manager IS NOT NULL AND (_manager = _user_id OR NOT EXISTS (
      SELECT 1 FROM public.crm_memberships WHERE user_id = _manager AND active AND role = 'BDM')) THEN
    RAISE EXCEPTION 'Manager must be an active BDM';
  END IF;
  INSERT INTO public.crm_memberships (user_id, role, manager_id, active)
  VALUES (_user_id, _role, _manager, coalesce((_input->>'active')::boolean, true))
  ON CONFLICT (user_id) DO UPDATE SET role = EXCLUDED.role, manager_id = EXCLUDED.manager_id, active = EXCLUDED.active;
  INSERT INTO public.crm_employee_profiles (user_id, employee_code, full_name, phone, designation, photo_url, joining_date)
  VALUES (_user_id, _code, btrim(_input->>'fullName'), btrim(coalesce(_input->>'phone', '')), btrim(coalesce(_input->>'designation', '')),
    nullif(btrim(coalesce(_input->>'photoUrl', '')), ''), coalesce(nullif(coalesce(_input->>'joiningDate', ''), '')::date, current_date))
  ON CONFLICT (user_id) DO UPDATE SET employee_code = EXCLUDED.employee_code, full_name = EXCLUDED.full_name, phone = EXCLUDED.phone,
    designation = EXCLUDED.designation, photo_url = EXCLUDED.photo_url, joining_date = EXCLUDED.joining_date;
END $$;

-- Exact-reference support lookup with safe fields only.
CREATE OR REPLACE FUNCTION public.crm_customer_lookup(_reference text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE _ref text := upper(btrim(coalesce(_reference, '')));
BEGIN
  IF public.crm_role() IS NULL THEN RAISE EXCEPTION 'CRM access required' USING ERRCODE = '42501'; END IF;
  IF length(_ref) < 6 THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', c.id, 'customer_code', c.customer_code, 'full_name', c.full_name, 'company', c.company,
      'acknowledgement', c.acknowledgement,
      'phone_last_4', CASE WHEN length(regexp_replace(c.phone, '\D', '', 'g')) >= 4 THEN right(regexp_replace(c.phone, '\D', '', 'g'), 4) END,
      'latest_stage', (SELECT l.stage FROM public.crm_leads l WHERE l.customer_id = c.id ORDER BY l.created_at DESC LIMIT 1),
      'open_tickets', (SELECT count(*) FROM public.crm_tickets t WHERE t.customer_id = c.id AND t.status <> 'resolved'),
      'created_at', c.created_at))
    FROM public.crm_customers c
    WHERE upper(c.customer_code) = _ref OR upper(coalesce(c.acknowledgement, '')) = _ref
       OR EXISTS (SELECT 1 FROM public.crm_tickets t WHERE t.customer_id = c.id AND upper(t.ticket_code) = _ref)), '[]'::jsonb);
END $$;

-- ===== Coordinators =====
CREATE OR REPLACE FUNCTION public.coordinator_name_for_code(_code text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT c.full_name FROM public.coordinators c WHERE c.active AND upper(c.referral_code) = upper(btrim(_code)) LIMIT 1),
    (SELECT p.full_name FROM public.crm_employee_profiles p JOIN public.crm_memberships m ON m.user_id = p.user_id AND m.active
      WHERE upper(p.employee_code) = upper(btrim(_code)) LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION public.coordinator_referral_stats()
RETURNS TABLE (coordinator_id uuid, leads bigint, submitted bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT s.cid, count(*)::bigint, count(*) FILTER (WHERE s.done)::bigint FROM (
    SELECT t.coordinator_id AS cid, true AS done FROM public.contact_submissions t WHERE t.coordinator_id IS NOT NULL
    UNION ALL SELECT t.coordinator_id, true FROM public.registration_applications t WHERE t.coordinator_id IS NOT NULL
    UNION ALL SELECT t.coordinator_id, true FROM public.foundation_submissions t WHERE t.coordinator_id IS NOT NULL
    UNION ALL SELECT t.coordinator_id, t.form_status = 'completed' FROM public.education_support_registrations t WHERE t.coordinator_id IS NOT NULL
    UNION ALL SELECT t.coordinator_id, t.submission_status = 'submitted' FROM public.young_innovators_registrations t WHERE t.coordinator_id IS NOT NULL
    UNION ALL SELECT t.coordinator_id, t.submission_status = 'submitted' FROM public.programme_applications t WHERE t.coordinator_id IS NOT NULL
  ) s GROUP BY s.cid;
END $$;

-- ===== Function execution rights =====
REVOKE EXECUTE ON FUNCTION public.consume_form_submission_limit(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_form_submission_limit(text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.crm_route_submission(text, uuid, text, text, text, text, text, text, text, numeric, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.crm_submission_lead(text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.crm_intake_submission() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_account_profile() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_approved_application_profile() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.assign_education_ack_number() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_education_approval() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.crm_owner_for_code(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.coordinator_name_for_code(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.first_admin_setup_status() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.claim_first_admin() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_save_employee(text, text, text, text, text, text, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_import_records(text, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_setup_metadata() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crm_create_lead(jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crm_assign_lead(uuid, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crm_onboard_member(uuid, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crm_customer_lookup(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.crm_import_submission(uuid, text, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.coordinator_referral_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.first_admin_setup_status(), public.claim_first_admin(),
  public.admin_save_employee(text, text, text, text, text, text, text, text), public.admin_import_records(text, jsonb),
  public.admin_setup_metadata(), public.crm_create_lead(jsonb), public.crm_assign_lead(uuid, uuid),
  public.crm_onboard_member(uuid, jsonb), public.crm_customer_lookup(text), public.crm_import_submission(uuid, text, uuid),
  public.coordinator_referral_stats(), public.crm_owner_for_code(text), public.coordinator_name_for_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_employee(text, text) TO anon, authenticated;

-- ===== Private storage access (buckets created separately) =====
CREATE POLICY "Admins read registration documents" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'registration-documents' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read customer report files" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'customer-reports' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins upload customer report files" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'customer-reports' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins replace customer report files" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'customer-reports' AND public.has_role(auth.uid(), 'admin'))
  WITH CHECK (bucket_id = 'customer-reports' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins delete customer report files" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'customer-reports' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read country logo files" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'country-logos' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins upload country logo files" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'country-logos' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins replace country logo files" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'country-logos' AND public.has_role(auth.uid(), 'admin'))
  WITH CHECK (bucket_id = 'country-logos' AND public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins delete country logo files" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'country-logos' AND public.has_role(auth.uid(), 'admin'));

-- ===== Payment option slots (links stay empty; the site falls back to its built-in payment pages) =====
INSERT INTO public.payment_options (key, programme, label, sort_order) VALUES
  ('education_sponsorship', 'Education Support', 'Sponsorship registration fee', 10),
  ('education_scholarship_25k', 'Education Support', 'Scholarship up to ₹25,000 registration fee', 20),
  ('education_scholarship_50k', 'Education Support', 'Scholarship up to ₹50,000 registration fee', 30),
  ('young_innovators_6_8', 'Young Innovators 2026', 'Class 6–8 registration fee', 40),
  ('young_innovators_9_10', 'Young Innovators 2026', 'Class 9–10 registration fee', 50),
  ('young_innovators_11_12', 'Young Innovators 2026', 'Class 11–12 registration fee', 60),
  ('funding_programme_registration', 'Funding Programme', 'Programme registration fee', 70),
  ('funding_programme_summit', 'Funding Programme', 'Optional summit package', 80),
  ('prototype_funding_registration', 'Prototype Funding Programme', 'Programme registration fee', 90)
ON CONFLICT (key) DO NOTHING;