# sophos-api-device-migration

Interaktives PowerShell-Skript zur Migration von Sophos-Central-Geräten
(Server oder Clients) von einem Tenant auf einen anderen Tenant über die
offizielle Sophos Central Endpoint-Migration-API.

## Ablauf

Beim Start fragt das Skript nacheinander ab:

1. **Anmeldung** – Sophos API Client-ID und Client-Secret
   (idealerweise Partner- oder Organisations-Credentials, damit beide
   Tenants mit einem Login erreichbar sind).
2. **Quell- und Ziel-Tenant** – Auswahl per GUI-Liste (`Out-GridView`).
3. **Was soll migriert werden?** – `[1] Server`, `[2] Clients`, `[3] Abbrechen`.
4. **Umfang** – `[1] Alle` Geräte migrieren oder `[2] Einzeln auswählen`:
   Es öffnet sich eine GUI-Liste aller Server/Clients des Quell-Tenants
   (Hostname, OS, letzter User, Health, zuletzt online) mit Mehrfachauswahl.
5. **Sicherheitsabfrage** und Start der Migration
   (Zwei-Schritt-Handshake: Job im Ziel-Tenant anlegen, im Quell-Tenant bestätigen).
6. **Status-Rückmeldung pro Gerät** – das Skript pollt den Migrationsstatus
   und meldet je Gerät `erfolgreich migriert`, `fehlgeschlagen` oder den
   aktuellen Zwischenstatus, inkl. Zusammenfassung am Ende.

## Verwendung

```powershell
.\Sophos-DeviceMigration.ps1
# oder mit Credentials als Parameter:
.\Sophos-DeviceMigration.ps1 -ClientId "xxxxxxxx-..." -ClientSecret "geheim"
```

## Voraussetzungen

- Windows PowerShell 5.1 oder PowerShell 7+
  (unter PS7 für die GUI-Auswahl das Modul `Microsoft.PowerShell.GraphicalTools`
  installieren; ohne GUI nutzt das Skript automatisch eine Konsolen-Auswahl).
- Sophos Central API-Credentials mit Zugriff auf Quell- **und** Ziel-Tenant
  (Partner: *Sophos Partner Dashboard → Einstellungen → API-Anmeldeinformationen*).
- Quell- und Ziel-Tenant müssen in **derselben Datenregion** liegen
  (Einschränkung der Sophos-Migration-API).

## Hinweise

- Offline-Geräte bleiben im Status *pending* und werden migriert, sobald sie
  sich das nächste Mal bei Sophos Central melden. Das Skript kann jederzeit
  mit `Strg+C` beendet werden – die Migration läuft serverseitig weiter.
- Richtlinien/Gruppen werden nicht mitgenommen; die Geräte landen im
  Ziel-Tenant in der Standardkonfiguration (Verhalten der Sophos-API).
