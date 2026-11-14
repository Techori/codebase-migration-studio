DROP POLICY IF EXISTS "Anyone reads payment options" ON public.payment_options;
CREATE POLICY "Visitors read configured payment options" ON public.payment_options
  FOR SELECT TO anon, authenticated
  USING (payment_link IS NOT NULL OR razorpay_button_id IS NOT NULL);
CREATE POLICY "Admins read all payment options" ON public.payment_options
  FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'::public.app_role));

DROP POLICY IF EXISTS "Anyone reads programme fees" ON public.country_programme_fees;
CREATE POLICY "Visitors read announced programme fees" ON public.country_programme_fees
  FOR SELECT TO anon, authenticated
  USING (amount IS NOT NULL);
CREATE POLICY "Admins read all programme fees" ON public.country_programme_fees
  FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'::public.app_role));