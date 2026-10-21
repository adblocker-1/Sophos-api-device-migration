# sophos-api-device-migration

## Kurzbeschreibung

Dieses PowerShell-Skript migriert Sophos-Central-Geräte (Server oder Clients)
über die offizielle Sophos-API von einem Tenant auf einen anderen – komplett
geführt per Dialog: Anmeldung wahlweise mit den API-Keys der beiden Tenants
oder einem Partner-Login, Auswahl der Geräte einzeln über eine GUI-Liste oder
alle auf einmal, danach automatischer Start der Migration mit laufender
Status-Rückmeldung pro Gerät und einer Ergebnis-Zusammenfassung am Ende.
Offline-Geräte werden serverseitig nachgezogen, sobald sie sich das nächste
Mal bei Sophos Central melden.

## Grafische Oberfläche (ab Version 2.0)

Neben dem Konsolen-Skript gibt es eine moderne Windows-Oberfläche:

```powershell
.\Sophos-DeviceMigration-GUI.ps1
```

oder einfach **`Start-GUI.cmd` doppelklicken** (startet ohne Konsolenfenster).

Der Assistent führt in vier Schritten durch die Migration:

1. **Anmeldung** – Tenant-API-Keys (Quell- und Ziel-Tenant) oder
   Partner-/Organisations-API-Key. Key-Typ, identische Tenants und
   Datenregion werden automatisch geprüft.
2. **Tenants** – nur beim Partner-Login: Quell- und Ziel-Tenant aus zwei
   durchsuchbaren Listen wählen.
3. **Geräte** – zwischen *Server* und *Clients* umschalten, per Suche filtern
   (Hostname, Betriebssystem, Benutzer) und Geräte per Checkbox markieren
   („Alle markieren“, „Auswahl aufheben“, mehrere Zeilen + Leertaste).
4. **Migration** – Zusammenfassung prüfen, starten und den Status pro Gerät
   live verfolgen: Kennzahlen (erfolgreich / fehlgeschlagen / ausstehend),
   Fortschrittsbalken, Protokoll, manuelle Statusabfrage und CSV-Export
   des Ergebnisses.

Alle API-Aufrufe laufen im Hintergrund, die Oberfläche bleibt dabei bedienbar;
Access-Tokens werden bei längeren Sitzungen automatisch erneuert.

> Hinweis: `Start-GUI.cmd` startet PowerShell mit `-ExecutionPolicy Bypass`,
> damit das heruntergeladene Skript ohne Änderung der Ausführungsrichtlinie läuft.

## Ablauf (Konsolen-Skript)

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

## Verwendung (Konsole)

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

- Windows PowerShell 5.1 oder PowerShell 7+ (die grafische Oberfläche
  benötigt Windows; unter PS7 für die GUI-Auswahl das Modul `Microsoft.PowerShell.GraphicalTools`
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

## Versionen

Die Änderungen je Version stehen im [CHANGELOG](CHANGELOG.md).
Fertige Pakete (ZIP mit allen Skripten) gibt es unter
[Releases](https://github.com/adblocker-1/sophos-api-device-migration/releases).
