# Personal Google OAuth setup

OpenMime needs an OAuth 2.0 **Desktop app** client. An API key cannot authorize access to private Gmail data.

## Create the project and client

1. Open [Google Cloud Console](https://console.cloud.google.com/) using the Google account that should own the project.
2. Create a project named `openmime-personal` (or select a dedicated existing project).
3. Open **APIs & Services → Library**, find **Gmail API**, and enable it. To use the optional contacts connection, also enable **People API**.
4. Open **Google Auth Platform** and configure Branding:
   - App name: `OpenMime`
   - User support email: your email
   - Developer contact email: your email
5. Under Audience, choose **External**. Keep Publishing status at **Testing** initially.
6. Add each Gmail address you want to connect under **Test users**.
7. Under Data Access, add `https://www.googleapis.com/auth/gmail.modify` plus the basic `openid` and `email` identity scopes if the Console asks you to declare scopes. For optional Contacts, add both `https://www.googleapis.com/auth/contacts.readonly` and `https://www.googleapis.com/auth/contacts.other.readonly`; the latter supplies interaction-derived Gmail autocomplete addresses.
8. Under Clients, choose **Create client → Desktop app** and name it `OpenMime macOS`.
9. Download the client JSON to your Mac.

## Connect OpenMime

1. Build and open the app:

   ```sh
   Scripts/build_app.sh debug
   open dist/OpenMime.app
   ```

2. Click **Choose Google OAuth JSON…** and select the downloaded file.
3. Click **Sign in with Google**.
4. Google will open in the default browser. Because the app is personal and unverified, Google may show a warning. Confirm that the project/app is yours, continue, and approve Gmail access.
5. The browser will show “Sign-in complete.” Return to OpenMime; it should display the Gmail address and mailbox totals.

## Optional Google Contacts

Open a composer and choose **Connect…** in the contacts banner. OpenMime starts a separate browser authorization requesting the read-only `contacts.readonly` and `contacts.other.readonly` scopes; it does not replace or broaden the existing Gmail token. Contacts are cached locally for name and address autocomplete, and can be disconnected independently in Settings. Gmail and locally learned address suggestions continue to work when Contacts is declined or unavailable.

Do not move the downloaded JSON into this repository. OpenMime does not need it again after importing the client configuration.

## Avoid weekly reauthorization

Testing-mode authorizations expire after seven days. Once login, relaunch, and token refresh have been proven, change the project's publishing status from **Testing** to **In production**. For a small personal-use app this can remain unverified; each account will click through Google's unverified-app warning when first connecting.

## Troubleshooting

- **Access blocked / user is not registered:** add the Gmail address as a test user while the project is in Testing.
- **Gmail API HTTP 403:** confirm Gmail API is enabled in the same project that owns the Desktop client.
- **No refresh token:** remove OpenMime from the Google Account's third-party access page, sign out in OpenMime, and authorize again.
- **Wrong client type:** create a Desktop app client. A Web application client has different redirect requirements and OpenMime intentionally rejects it.
