# Calendar Phase 0: test accounts and OAuth registration

Checked against provider documentation on 2026-10-31. These steps prepare the
real-account qualification in [Phase 0](calendar-phase0.md) of the
[calendar plan](calendar.md). The current prototype does **not** implement
browser sign-in or token storage yet; registering clients does not make the
local probes contact either provider.

## Prepare three test accounts

Use a dedicated Google account, a dedicated personal Microsoft account with
Outlook.com Calendar, and an organization-approved Microsoft 365 work/school
test account with a working Exchange Online mailbox. Verify each can open its
calendar in the provider's browser UI. An Entra directory user alone does not
establish that a calendar mailbox is available. [Microsoft mailbox support](https://learn.microsoft.com/en-us/graph/outlook-mail-concept-overview)

Keep these accounts free of real appointments. In each browser calendar,
create an owned secondary calendar named `RediWM Phase 0` and retain the
account's primary calendar for primary-calendar cases. Use events without
attendees initially. Primary and secondary calendars must both be tested;
passing a personal Microsoft account does not qualify a work/school account.

Register development clients under an owner who will retain access to the
Google project and Microsoft tenant. If there is no suitable Microsoft test
tenant or mailbox, record that prerequisite as pending and arrange access
with its administrator; a personal account cannot substitute for it.

## Google

1. Open the [Google Cloud console](https://console.cloud.google.com/), create
   or select a development project, and enable **Google Calendar API** under
   **APIs & Services → Library**. Record the project ID and owner.
2. Open **Google Auth platform → Branding**. If prompted, choose **Get
   started**; enter an app name such as `RediWM Calendar Phase 0`, support
   email and developer contact. Choose **External** as the audience.
3. Under **Audience**, keep the project in **Testing** and add the dedicated
   Google account under **Test users**. Under **Data Access**, add the scopes
   below. [Google consent configuration](https://developers.google.com/workspace/guides/configure-oauth-consent)
4. Under **Google Auth platform → Clients → Create client**, select
   **Desktop app**, name it, and create it. Record its public client ID.
   The eventual harness will open the system browser and use authorization
   code flow with PKCE and a loopback callback. Google permits a desktop
   callback such as `http://127.0.0.1:<port>`; the harness will choose and bind
   the port. [Google desktop registration and flow](https://developers.google.com/identity/protocols/oauth2/native-app)

The proposed **native Calendar REST** access is:

| Scope | Purpose |
| --- | --- |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | Discover calendars already available to the account |
| `https://www.googleapis.com/auth/calendar.events` | Read and change events |
| `openid email` | Identify the signed-in account; requested by the future sign-in harness |

Calendar creation and sharing are outside this initial scope. Creating the
test secondary calendar in the browser avoids requiring calendar-management
permissions just to prepare the fixture. [Calendar scope reference](https://developers.google.com/workspace/calendar/api/auth)

EDS uses Google's CalDAV interface, so these REST scopes do **not** establish
that EDS will work. Its reduced-scope discovery, sign-in and renewal remain
qualification gates. Enable Google's CalDAV API in the development project
when running that candidate, following the [CalDAV setup guide](https://developers.google.com/workspace/calendar/caldav/v2/guide).

External projects in Testing receive seven-day refresh tokens when calendar
access is requested. Record this expected expiry separately from a backend
failure. Production publishing and applicable OAuth verification must be
completed before release; Testing is sufficient for the development runs.
[Google refresh-token expiry](https://developers.google.com/identity/protocols/oauth2#expiration),
[verification requirements](https://developers.google.com/workspace/guides/configure-oauth-consent#scope_categories)

## Microsoft: one registration, two account classes

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com/)
   in a tenant where you may register applications. If registration is
   restricted, ask the tenant administrator to create this development client
   or grant the appropriate developer role.
2. Open **Entra ID → App registrations → New registration**. Name the app
   `RediWM Calendar Phase 0`. Select the audience that includes **any Entra ID
   tenant and personal Microsoft accounts**; older portal wording is
   **Accounts in any organizational directory and personal Microsoft
   accounts**. Register and record the **Application (client) ID**, owning
   **Directory (tenant) ID** and registration owner. [App registration](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)
3. Under **Authentication → Add a platform → Mobile and desktop
   applications**, add **`http://localhost`** as the system-browser redirect
   and save. This configures a native/public-client callback. The eventual
   harness will use a loopback listener; localhost matching permits an
   ephemeral port. Keep the callback path consistent with the registration.
   [Desktop configuration](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration),
   [localhost matching](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url#localhost-exceptions)
4. Under **API permissions → Add a permission → Microsoft Graph → Delegated
   permissions**, add **`Calendars.ReadWrite`**. Add the OIDC permissions
   **`openid`**, **`profile`** and **`offline_access`** for sign-in, account
   display and renewal. Remove an unused default `User.Read` permission if
   present: this prototype intends to use the ID token for account identity,
   rather than reading the user's Graph profile. [Permission setup](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-access-web-apis),
   [OIDC permissions](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc)

The future harness must request those scopes in its authorization-code flow
with PKCE, using the `common` authority to allow both account classes. Do not
create a client secret for this desktop client. The flow obtains refresh
tokens through `offline_access`; enabling only a permission in the portal
does not replace requesting it during authorization. [Microsoft code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)

`Calendars.ReadWrite` must be **delegated**, not the application permission
of the same name. It supports personal accounts and does not itself require
administrator consent, but organizational consent policy and conditional
access can still require approval or prevent sign-in. Obtain the test
tenant's required approval and record the result; do not relax its policies
to claim support. [Calendar permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#calendarsreadwrite)

EDS/evolution-ews must separately demonstrate that its initial sign-in and
refresh use only the agreed permissions. Its stock OAuth adapter requests
broader permissions; creating this registration alone does not narrow that
adapter. [Current Microsoft365 adapter](https://raw.githubusercontent.com/GNOME/evolution-ews/master/src/Microsoft365/common/e-oauth2-service-microsoft365.c)

## What to record now

Record registration ownership, public client IDs, account classes available,
configured redirect and scope names, and whether tenant approval is pending.
Public client IDs identify apps; they are not account passwords or tokens.
Google's desktop configuration may also contain a field named `client_secret`;
a desktop app cannot keep that field confidential, and it must never replace
PKCE. Keep downloaded credential files out of the repository and chat.
[Google public-client model](https://developers.google.com/identity/protocols/oauth2/native-app)

Do not paste passwords, authorization codes, access tokens or refresh tokens
into chat, logs, argv or plaintext prototype files. The real-account harness
still needs browser authorization and qualified keyring storage before any
token can be used. No manual token export is needed for this preparation.

## Qualification once the real-account harness exists

For each of the three account classes and each backend candidate under test:

- Record package versions, requested/granted scope names and the calendar
  capability matrix; capture no tokens or private calendar contents.
- Create, fetch, edit and delete a uniquely named event from the harness;
  make a browser-side edit and confirm it arrives locally. Repeat on primary
  and secondary owned calendars.
- Create a recurring series, move one occurrence and delete another; verify
  original occurrence identity and whole-series reads, including Graph masters.
- Edit while offline, restart the prototype, reconnect and confirm one
  remote update. Simulate a lost create response and verify no duplicate.
- Make concurrent browser/local edits and verify a visible conflict without
  silently losing either version. Exercise a moved occurrence at the cache
  boundary and invalid sync state while pending work exists.
- Exercise token renewal, cancellation, revocation/reconnect and a locked
  keyring. Confirm renewal does not broaden scopes or activate mail/tasks.
- Record pass/fail/pending evidence in [the Phase 0 record](calendar-phase0.md).
  Browser login alone and the current local probes cannot pass these gates.
