-- =====================================================================
-- NammaStay · 019_prices_oct_2026.sql
-- New subscription prices (flat price per property, 15-day free trial):
--   Hostel / PG           ₹3,999 / month   ₹27,999 / year
--   Homestay (≤ 6 rooms)  ₹1,999 / month   ₹12,999 / year
--   Hotel small (≤ 20)    ₹3,999 / month   ₹27,999 / year
--   Hotel mid (21–50)     ₹6,999 / month   ₹45,999 / year
--   Hotel large (51+)     custom quote (unchanged)
-- Existing paid-until dates are not changed; new prices apply to the
-- next payment. Change prices later in the app: Subscribers → Billing settings.
-- Run AFTER 015_plans_by_type.sql.
-- =====================================================================
update public.plans set price_paise = 399900,  description = 'Billed every month'                 where id = 'monthly';
update public.plans set price_paise = 2799900, description = 'Save ₹19,989 a year'                where id = 'yearly';
update public.plans set price_paise = 199900,  description = 'Homestays up to 6 rooms'            where id = 'homestay_monthly';
update public.plans set price_paise = 1299900, description = 'Homestays · save ₹10,989 a year'    where id = 'homestay_yearly';
update public.plans set price_paise = 399900,  description = 'Hotels up to 20 rooms'              where id = 'hotel_s_monthly';
update public.plans set price_paise = 2799900, description = 'Up to 20 rooms · save ₹19,989 a year' where id = 'hotel_s_yearly';
update public.plans set price_paise = 699900,  description = 'Hotels with 21–50 rooms'            where id = 'hotel_m_monthly';
update public.plans set price_paise = 4599900, description = '21–50 rooms · save ₹37,989 a year'  where id = 'hotel_m_yearly';

-- check
select id, kind, name, price_paise / 100 as price_rupees, description from public.plans order by sort;
