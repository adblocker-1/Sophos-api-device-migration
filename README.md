# sophos-api-device-migration

Interaktives PowerShell-Skript zur Migration von Sophos-Central-Geräten
(Server oder Clients) von einem Tenant auf einen anderen Tenant über die
offizielle Sophos Central Endpoint-Migration-API.

## Ablauf

Beim Start fragt das Skript nacheinander ab:

1. **Anmeldeart wählen:**
   - `[1] Tenant-API-Keys` (Standard-Variante): Es werden nacheinander die
     API-Credentials (Client-ID / Client-Secret) des **Quell-Tenants** und des
     **Ziel-Tenants** abgefragt. Ein Partner-Login ist nicht nötig.
   - `[2] Partner-/Organisations-API-Key`: Ein einziger Login; Quell- und
     Ziel-Tenant werden anschließend bequem aus einer GUI-Liste aller
     Tenants ausgewählt.
2. **Was soll migriert werden?** – `[1] Server`, `[2] Clients`, `[3] Abbrechen`.
3. **Umfang** – `[1] Alle` Geräte migrieren oder `[2] Einzeln auswählen`:
   Es öffnet sich eine GUI-Liste aller Server/Clients des Quell-Tenants
   (Hostname, OS, letzter User, Health, zuletzt online) mit Mehrfachauswahl.
4. **Sicherheitsabfrage** und Start der Migration
   (Zwei-Schritt-Handshake: Job im Ziel-Tenant anlegen, im Quell-Tenant bestätigen).
5. **Status-Rückmeldung pro Gerät** – das Skript pollt den Migrationsstatus
   und meldet je Gerät `erfolgreich migriert`, `fehlgeschlagen` oder den
   aktuellen Zwischenstatus, inkl. Zusammenfassung am Ende.

## Verwendung

```powershell
.\Sophos-DeviceMigration.ps1
```

Alle Eingaben (API-Keys, Auswahl) werden interaktiv abgefragt;
Client-Secrets werden dabei verdeckt eingegeben.

## API-Keys erstellen

- **Tenant-API-Key** (Variante 1, je Tenant einmal nötig):
  *Sophos Central Admin → Globale Einstellungen → API-Anmeldeinformationen →
  Anmeldeinformationen hinzufügen* (Rolle: mindestens „API – Superadmin"
  für Migrationen).
- **Partner-API-Key** (Variante 2, optional):
  *Sophos Partner Dashboard → Einstellungen → API-Anmeldeinformationen*.

## Voraussetzungen

- Windows PowerShell 5.1 oder PowerShell 7+
  (unter PS7 für die GUI-Auswahl das Modul `Microsoft.PowerShell.GraphicalTools`
  installieren; ohne GUI nutzt das Skript automatisch eine Konsolen-Auswahl).
- API-Credentials für Quell- **und** Ziel-Tenant (siehe oben) – entweder
  zwei Tenant-Keys oder ein Partner-/Organisations-Key.
- Quell- und Ziel-Tenant müssen in **derselben Datenregion** liegen
  (Einschränkung der Sophos-Migration-API); das Skript prüft das automatisch.

## Hinweise

- Offline-Geräte bleiben im Status *pending* und werden migriert, sobald sie
  sich das nächste Mal bei Sophos Central melden. Das Skript kann jederzeit
  mit `Strg+C` beendet werden – die Migration läuft serverseitig weiter.
- Richtlinien/Gruppen werden nicht mitgenommen; die Geräte landen im
  Ziel-Tenant in der Standardkonfiguration (Verhalten der Sophos-API).
