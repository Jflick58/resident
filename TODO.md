# To do (yours)

- [ ] **GitHub connector:** create an OAuth app at github.com/settings/developers
      with the callback `com.jflick.resident://oauth`, then give Claude its client
      ID. Tick Enable Device Flow; no secret is needed. Until then GitHub can be added by
      hand in Settings > Connectors > Add Connector > Advanced.
- [ ] **Gmail and Google Calendar connectors:** in Google Cloud Console create
      a project, enable the Gmail API and Google Calendar API (and their MCP
      services if listed), set up the OAuth consent screen with yourself as a
      test user, then create an OAuth client of type **iOS** with bundle ID
      `com.jflick.resident`. In the app: Settings > Connectors > Add Connector,
      paste the client ID under Advanced, then tap Gmail or Google Calendar.
      Google's servers are in developer preview and may need your account
      enrolled in the Workspace Developer Preview Program. Sign-in against
      Google is untested until this exists.
