-- The acknowledgement trigger fills this in; an empty default lets inserts omit it.
ALTER TABLE public.education_support_registrations ALTER COLUMN ack_number SET DEFAULT '';