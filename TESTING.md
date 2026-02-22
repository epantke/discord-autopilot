# Pre-Release Test Checklist

Manuelle Testliste für alle Kernbereiche. Vor jedem Release durchgehen, Ergebnisse unten tracken.

## Voraussetzungen

- [ ] Test-Discord-Server mit Bot eingeladen (Message Content Intent + Server Members Intent)
- [ ] `.env` konfiguriert: `DISCORD_TOKEN`, `GITHUB_TOKEN`, `REPO_PATH`, `ALLOWED_GUILDS`, `ADMIN_USER_ID`, `STARTUP_CHANNEL_ID`
- [ ] `ADMIN_ROLE_IDS` auf eine Rolle gesetzt die dein Test-User hat
- [ ] Zweiter Discord-Account ohne Admin-Rolle vorhanden (für H-Tests)
- [ ] Terminal-Zugriff auf den Bot-Prozess

---

## A — Startup & Config

### A1 · Bot-Start
1. Bot starten: `npm start`
2. **Expected:** Presence zeigt `Watching v{version} · 🖤`
3. **Expected:** Startup-Notification erscheint im `STARTUP_CHANNEL_ID`

### A2 · /config
1. `/config` im Discord ausführen
2. **Expected:** Ephemeral-Antwort mit allen konfigurierten Werten (Token redacted, Guilds, Channels, etc.)

### A3 · Fehlende Token-Validierung
1. Bot stoppen
2. `DISCORD_TOKEN` aus `.env` entfernen
3. Bot starten
4. **Expected:** Prozess beendet sich sofort mit Fehlermeldung, kein Crash-Loop
5. `DISCORD_TOKEN` wiederherstellen

### A4 · Ungültiges Repo
1. `REPO_PATH` auf ein nicht-existierendes Verzeichnis setzen (z.B. `/tmp/does-not-exist`)
2. Bot starten
3. **Expected:** Fehlermeldung bzgl. Git-Repo, sauberer Exit
4. `REPO_PATH` wiederherstellen

---

## B — Task-Flow: @mention + DM

### B1 · @mention → Thread
1. In einem erlaubten Channel: `@Bot Was ist 2+2?`
2. **Expected:** Bot erstellt einen Thread und antwortet mit dem Ergebnis (4)
3. **Expected:** Typing-Indicator während der Verarbeitung sichtbar

### B2 · Thread Follow-up
1. Im Thread aus B1: `Und was ist 3+3?`
2. **Expected:** Bot verarbeitet die Nachricht als Follow-up, Antwort erscheint im gleichen Thread

### B3 · DM (erlaubt)
1. Als `ADMIN_USER_ID` eine DM an den Bot senden: `Hallo`
2. **Expected:** Bot antwortet in der DM

### B4 · DM (nicht erlaubt)
1. Von einem Account der NICHT in `ADMIN_USER_ID` oder `ALLOWED_DM_USERS` ist, eine DM senden
2. **Expected:** Keine Antwort, Nachricht wird ignoriert

---

## C — Queue & Kontrolle

### C1 · Task-Queue
1. `@Bot Schreibe mir eine ausführliche Erklärung von Rekursion` (langer Task)
2. Sofort eine zweite @mention: `@Bot Was ist 1+1?`
3. **Expected:** Queue-Hinweis für zweiten Task, beide werden nacheinander verarbeitet

### C2 · /stop
1. `@Bot Erkläre mir ausführlich die Geschichte von JavaScript` (langer Task)
2. Während der Task läuft: `/stop`
3. **Expected:** Task wird abgebrochen, Bestätigung erscheint

### C3 · /pause + /resume
1. `/pause`
2. **Expected:** Bestätigung "Session pausiert"
3. `@Bot Hallo` senden
4. **Expected:** Task wird gequeued, aber nicht verarbeitet
5. `/resume`
6. **Expected:** Bestätigung, gequeuter Task wird jetzt verarbeitet

---

## D — Slash Commands

### D1 · /model current
1. `/model action:current`
2. **Expected:** Zeigt aktuell verwendetes Modell

### D2 · /model list
1. `/model action:list`
2. **Expected:** Liste verfügbarer Modelle

### D3 · /model set
1. `/model action:set name:{ein Modell aus D2}`
2. **Expected:** Bestätigung "Modell gewechselt"
3. `/model action:current` → neues Modell wird angezeigt

### D4 · /reset
1. `/reset`
2. **Expected:** "Session zurückgesetzt"
3. `@Bot Hallo`
4. **Expected:** Neue Session wird erstellt, Antwort kommt

### D5 · /repo
1. `/repo action:set url:epantke/remote-coding-agent`
2. **Expected:** Repo-Override gesetzt, Clone-Vorgang
3. `/repo action:current`
4. **Expected:** Zeigt `epantke/remote-coding-agent`
5. `/repo action:reset`
6. **Expected:** Zurück zum Default-Repo

---

## E — Push-Approval

### E1 · Push-Gate erscheint
1. `@Bot Erstelle eine Datei namens test-release.txt mit dem Inhalt "hello world", committe sie und pushe zum Remote`
2. **Expected:** Bot erstellt Datei + Commit, dann erscheint Push-Approval-Embed mit:
   - Approve (grün) + Reject (rot) Buttons
   - Branch-Name, letzte Commits, Diff-Stats
   - Command ist sichtbar (ggf. redacted)

### E2 · Push ablehnen
1. "Reject" Button klicken
2. **Expected:** Push blockiert, Bot meldet Ablehnung, Buttons werden deaktiviert

---

## F — Workspace-Boundary & Grants

### F1 · Zugriff außerhalb Workspace
1. `@Bot Lies die Datei C:\Windows\System32\drivers\etc\hosts` (Windows) oder `@Bot Lies /etc/hosts` (Linux)
2. **Expected:** Zugriff blockiert, Bot meldet dass die Datei außerhalb des Workspace liegt, Hinweis auf `/grant`

### F2 · Grant erteilen + nutzen
1. `/grant path:C:\Windows mode:ro ttl:5` (Windows) oder `/grant path:/etc mode:ro ttl:5` (Linux)
2. **Expected:** Grant-Bestätigung
3. Gleiche Anfrage wie F1 wiederholen
4. **Expected:** Datei wird gelesen und Inhalt angezeigt

### F3 · Grant widerrufen
1. `/revoke path:C:\Windows` (oder `/revoke path:/etc`)
2. **Expected:** Revoke-Bestätigung
3. Gleiche Leseanfrage wie F1 nochmal
4. **Expected:** Wieder blockiert

---

## G — Secret Scanning

### G1 · Token-Redaktion
1. `@Bot Schreibe folgenden Code und führe ihn aus: console.log(process.env.DISCORD_TOKEN)`
2. **Expected:** Output enthält `[REDACTED]` oder ähnlich, **niemals** den echten Token-Wert

---

## H — Responders & RBAC

### H1 · Responders verwalten
1. `/responders action:add user:@ZweiterUser`
2. **Expected:** Bestätigung
3. `/responders action:list`
4. **Expected:** Zweiter User wird aufgelistet
5. `/responders action:remove user:@ZweiterUser`
6. **Expected:** Bestätigung

### H2 · Non-Admin RBAC
1. Mit dem zweiten Account (ohne Admin-Rolle): `/config` oder `/stop` versuchen
2. **Expected:** Fehlermeldung "Keine Berechtigung" oder Command nicht sichtbar/ausführbar

---

## I — Crash Recovery

### I1 · Graceful Shutdown + Recovery
1. `@Bot Erkläre mir ausführlich die Geschichte des Internets` (langer Task starten)
2. Im Terminal: `Ctrl+C` drücken
3. **Expected:** "Shutting down" Nachricht in Discord, Bot beendet sich sauber
4. Bot neu starten: `npm start`
5. **Expected:** Stale Session wird erkannt und zurückgesetzt, Recovery-Hinweis im betroffenen Channel (und/oder Retry-Button)

---

## J — Build & Update

### J1 · Build-Verifikation
1. `node build.mjs` ausführen
2. **Expected:** `dist/agent.sh` und `dist/agent.ps1` existieren
3. In beiden Dateien nach `SCRIPT_VERSION` suchen
4. **Expected:** Zeigt die aktuelle Version aus `package.json` (nicht `0.0.0-dev`)

### J2 · Update-Check
1. `/update action:check`
2. **Expected:** "Kein Update verfügbar" oder zeigt neuere Version mit Details an

---

## Ergebnis-Tracking

Kopiere diese Tabelle für jedes Release und fülle sie aus:

```
Release: v_____ | Datum: ____-__-__ | Tester: __________

| Bereich      | Tests | Pass | Fail | Notizen |
|--------------|-------|------|------|---------|
| Startup      | A1-A4 |      |      |         |
| Task-Flow    | B1-B4 |      |      |         |
| Queue        | C1-C3 |      |      |         |
| Commands     | D1-D5 |      |      |         |
| Push Gate    | E1-E2 |      |      |         |
| Boundary     | F1-F3 |      |      |         |
| Secrets      | G1    |      |      |         |
| RBAC         | H1-H2 |      |      |         |
| Recovery     | I1    |      |      |         |
| Build        | J1-J2 |      |      |         |
```
