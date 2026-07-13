-- Point plans at test-mode Stripe prices while STRIPE_SECRET_KEY is sk_test.
-- At launch, flip back to the live ids:
--   pro: price_1TseiK2NOktmyAyMomFqP0O5, max: price_1TsejL2NOktmyAyMcZFlHmOv
update public.available_plans set stripe_price_id = 'price_1TsfaV2NOktmyAyMcFJrdiAk' where tier = 'pro';
update public.available_plans set stripe_price_id = 'price_1TsfaW2NOktmyAyMADt1o49a' where tier = 'max';
