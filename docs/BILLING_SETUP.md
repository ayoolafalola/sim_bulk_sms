# Comeriver Pro: setting up subscriptions

The free app has a signature on every campaign text and email ("Sent via messages.comeriver.com"),
up to 5 saved campaigns, 1 schedule and 50 emails a day. **Comeriver Pro** removes these limits and lets the
user change or remove the signature. There is no free trial: the free app is the trial.

Purchases use Flutter's `in_app_purchase` plugin and are checked on the phone with Google Play / the App Store
(no server). The code keeps product ids in `lib/domain/models/pro.dart` (`ProProducts`) and every Pro feature in
`ProFeature`; add a feature there and check `ProStatus.has(...)` where it applies.

## Google Play

Play only lets you create subscriptions after an app bundle that includes billing has been uploaded.

1. **Payments profile:** Play Console › Settings › Payments profile (merchant account). Needed to sell anything.
2. **Upload a build:** `flutter build appbundle` › Play Console › Test and release › Testing › **Internal testing**
   › Create release › upload the .aab › add yourself as a tester and install from the opt-in link.
3. **Create the subscription:** Monetise with Play › Products › **Subscriptions** › Create subscription:
   - Product ID: **`comeriver_pro`** (must match exactly) · Name: "Comeriver Pro".
   - Add base plan **`monthly`**: auto-renewing, billing period 1 month, set prices (Play converts to local
     currencies; review the ₦ price), grace period 7 days recommended.
   - Add base plan **`yearly`**: auto-renewing, 1 year, prices.
   - No offers (no free trial). Activate both base plans.
4. **License testers:** Play Console › Settings › **License testing** › add your Google account. Test purchases are
   then free and renew quickly (a monthly renewal every few minutes).
5. **Test on the phone:** Settings › Comeriver Pro › Monthly or Yearly › buy with the test card › the app shows
   "Pro is on". Cancel in Play › Payments & subscriptions; after it expires, open the app: it is back to Free.
   Restore purchases and Manage subscription are on the same screen.

How the app knows: on start, on returning to the app and after a purchase it asks Play for active purchases.
If Play can't be reached, the last confirmed Pro status counts for up to 7 days. Purchases are acknowledged
automatically (Play refunds unacknowledged purchases after 3 days).

## App Store (when the iOS app is built and signed)

1. App Store Connect › Agreements, Tax and Banking › accept the **Paid Apps** agreement and add bank/tax details.
2. Your app › Monetisation › **Subscriptions** › create the group **"Comeriver Pro"** with two auto-renewable
   subscriptions: **`comeriver_pro_monthly`** (1 month) and **`comeriver_pro_yearly`** (1 year); prices,
   localised display names, review screenshot. No introductory offer.
3. Xcode › Runner target › Signing & Capabilities › **+ In-App Purchase**.
4. Test with a **Sandbox** account (App Store Connect › Users and Access › Sandbox) or a StoreKit configuration file.

On iOS the app reads the subscription's real expiry date from StoreKit 2; it stays Pro until 3 days after it.

## Debug builds

Settings › Comeriver Pro › **Pretend Pro (debug builds only)** turns every Pro feature on without buying,
to try them. It isn't shown in release builds.

## Store listing and review

- Say in the listing that the app is free with a signature on campaign messages and limits, and that
  Comeriver Pro removes them (store_listing.md has the wording).
- Reviewers can see Pro without paying only with a license-test account; mention in reviewer notes that the
  free app is fully usable and Pro only lifts limits.
