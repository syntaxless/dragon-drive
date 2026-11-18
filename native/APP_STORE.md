# App Store submission sheet

Everything App Store Connect asks for, filled in where it can be. Items marked **(you)** need Chefff.

## Before the first upload

1. **Supabase** (you): run `supabase/safety.sql` in the SQL editor. Without it, Delete account, Report and Block show an error.
2. **Review account** (you): Supabase, Authentication, Users, *Add user*, *Create new user* with an email you control (for example `appreview@turboloser.co`), a password, and *Auto confirm* on. Sign in to it once on the website (Sign in with a password), pick a handle like `@appreview`, follow @burnout, and record or import one short drive so the reviewer sees a populated app.
3. **Bundle ID** (you): developer.apple.com, Certificates, Identifiers & Profiles, Identifiers, +, App IDs, App: description "Dragon Drive", explicit Bundle ID `com.itschefff.dragondrive`. No extra capabilities are needed (background location is an Info.plist mode, not a capability).
4. **App record** (you): App Store Connect, Apps, +, New App: iOS, name (below), language English (U.S.), bundle ID `com.itschefff.dragondrive`, SKU `dragondrive`, Full Access.
5. **Build** (you): see `README.md` (Archive, Upload), then test it from TestFlight on your phone: record a drive with the screen locked, sign in with the email code, report, block, delete a test account.

## Listing

| Field | Value |
| --- | --- |
| Name (30) | Dragon Drive (if Apple says it's taken because of "DragonDrive", use **Dragon Drive: Drive Log**) |
| Subtitle (30) | Drive your junk |
| Primary category | Navigation |
| Secondary category | Social Networking |
| Price | Free |
| Privacy Policy URL | https://dragondrive.turboloser.co/privacy.html |
| Support URL | https://dragondrive.turboloser.co/support.html |
| Marketing URL | https://dragondrive.turboloser.co |
| Copyright | 2026 Chefff's legal name (you), later Slam Dunk Ltd. |
| Keywords (100) | `car,drive,logbook,gps,road trip,0-60,quarter mile,g-force,cruise,racebox,project car,garage,route` |

**Promotional text (170):** Put miles on your project car. Log every drive, see your route, speed, elevation and g-force, and share it with your crew.

**Description:**

> Drive your junk. Dragon Drive is a logbook for the cars you love driving.
>
> Tap Drive and go. Dragon Drive records your route, distance, moving time, average and top speed, elevation and g-force, and picks out your 0-60, 60-130, 60 ft, eighth and quarter mile times on its own.
>
> SEE EVERY DRIVE
> - Your route on a street map, in Streets, Light, Dark, Synthwave or Game Boy style
> - Speed and elevation charts and a friction circle of your acceleration, braking and cornering
> - Keeps recording with the screen locked
>
> SHARE WITH YOUR CREW
> - Follow friends and see their drives, give kudos and comment
> - Drives with friends on the same roads group into a cruise automatically
> - Plan a route and share it so everyone follows the same line
> - Make a share card with your photo, or a video with your speed and g-force burned in
>
> YOUR GARAGE
> - A page for each car with photos, mods and its drive stats
>
> PRIVATE BY DEFAULT
> - Each drive is Followers, Everyone or Only me
> - The start and end of shared routes are hidden so they don't show where you live
> - No ads, no tracking
>
> Timed runs are for tracks and drag strips. Drive safely and obey the law.

**What's New (1.0):** First release.

**Screenshots** (you take them; Claude can frame them): iPhone 6.9" display, 1320 x 2868 portrait, 3 to 10 of them. Suggested: feed, a drive with map and stats, timed runs and g-force, driving screen, garage page, share card. Simulator: iPhone 17 Pro Max (or 16 Pro Max), File, Save Screen.

## App Privacy (the "nutrition label")

Data collection: **Yes**. Tracking: **No** (no ads, no data brokers, nothing shared with other companies' apps).

| Data type | Linked to the user | Used for tracking | Purpose |
| --- | --- | --- | --- |
| Contact Info: Email Address | Yes | No | App Functionality |
| Location: Precise Location | Yes | No | App Functionality |
| User Content: Photos or Videos | Yes | No | App Functionality |
| User Content: Other User Content (comments, drive titles, garage text, reports) | Yes | No | App Functionality |
| Identifiers: User ID | Yes | No | App Functionality |

Not collected: Health, Financial, Contacts, Browsing or Search History, Usage Data, Diagnostics, Purchases, Sensitive Info. (Drive videos and motion data stay on the phone, and data that never leaves the device doesn't count as collected.)

## Age rating

Answer the questionnaire honestly; the relevant answers: no violence, sexual content, profanity, gambling or alcohol; **User-Generated Content: Yes**, **Messaging and Chat: Yes** (comments), **Advertising: No**, **Age Assurance / Parental Controls: No**. Expect 13+. Set the minimum to 13+ if asked, matching the Terms.

## App Review notes (paste into App Review Information)

> Sign-in: Dragon Drive normally signs in with a one-time code sent by email. For review, tap the You tab (top right avatar), scroll to "Sign in or create an account", tap "Sign in with a password", enter the email above and the password below.
>
> Demo account: (email) / (password)  ← (you)
>
> Recording a drive works without an account: tap the wheel button at the bottom, then Start. The app uses location in the background only while a drive is recording (blue location indicator), so a drive keeps logging with the screen locked; it stops when you hold Finish.
>
> User-generated content safeguards (Guideline 1.2): new users agree to the Terms (zero tolerance for objectionable content) before choosing a handle; every drive, comment, post, route and profile has Report; profiles have Block, which hides both users' content from each other at the database level; reports email our moderation inbox, and we act on them within 24 hours.
>
> Account deletion (Guideline 5.1.1(v)): You tab, Account, Delete account, type DELETE.
>
> Timed runs (0-60, quarter mile) are measured from any drive and are intended for tracks and drag strips; there are no leaderboards or competition between users.

Contact information: your name, phone and email (you).

## Review risks and how they're covered

- **4.2 Minimum functionality** (web apps in a wrapper): the app bundles its files and works offline, records in the background with native location, keeps the screen awake, and has its own accounts and social features. Native Bluetooth for RaceBox is the next native feature if review pushes back.
- **1.2 User-generated content**: report, block, Terms agreement, 24-hour moderation (`supabase/moderation.sql`). Apple's list also mentions filtering objectionable material before it's posted; there's no word filter yet. Reviewers usually accept report + block + moderation; if they ask, add a filter.
- **1.4.1 / 1.4.5 Physical harm**: timed runs could read as encouraging street racing. The Terms and description say tracks and drag strips, and there are no leaderboards.
- **5.1.1(v) Account deletion**: in the app, removes server data and photos.
- **2.5.4 Background location**: used only while recording; the purpose strings say so.
- **4.8 Sign in with Apple**: not required, because the app uses its own email sign-in, not Google/Facebook/etc.
- **Names**: an existing App Store app is called "DragonDrive" (Dragontail Systems). If the name is rejected as taken, use the fallback above; the Home Screen name stays "Dragon Drive".

## Moving to Slam Dunk Ltd. later

App Store Connect, the app, App Information, *Transfer App*, once the organization account exists. The bundle ID, reviews and TestFlight testers move with it. Change the copyright line and the Privacy Policy's "we" at the same time.
