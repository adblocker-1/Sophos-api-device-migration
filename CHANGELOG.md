# Changelog

## 2.0

### Neu: Grafische Oberfläche (`Sophos-DeviceMigration-GUI.ps1`)

- Moderner WPF-Assistent in vier Schritten: **Anmeldung → Tenants → Geräte → Migration**,
  mit Schritt-Anzeige in der Seitenleiste.
- **Anmeldung** wahlweise per Tenant-API-Keys (Quell- und Ziel-Tenant) oder per
  Partner-/Organisations-API-Key; Prüfung auf Key-Typ, identische Tenants und Datenregion.
- **Tenant-Auswahl** (Partner-Login) in zwei durchsuchbaren Listen mit Live-Warnung bei
  gleichem Tenant oder unterschiedlicher Region.
- **Geräteliste** mit Umschalter Server/Clients, Suche (Hostname, OS, Benutzer),
  Checkbox-Auswahl, „Alle markieren“/„Auswahl aufheben“, Sortierung, farbiger
  Health-Anzeige und Mehrfach-Umschalten per Leertaste.
- **Migration** mit Zusammenfassung, Sicherheitsabfrage, Live-Status pro Gerät
  (farbige Status-Badges), Kennzahlen (erfolgreich / fehlgeschlagen / ausstehend),
  Fortschrittsbalken, Protokoll, manueller Statusabfrage und **CSV-Export** des Ergebnisses.
- Alle API-Aufrufe laufen im Hintergrund – die Oberfläche bleibt bedienbar.
- Access-Tokens werden bei längeren Sitzungen automatisch erneuert.
- Verständliche Fehlermeldungen inkl. Fehlertext der Sophos-API.
- `Start-GUI.cmd` zum Starten per Doppelklick (ohne Konsolenfenster).

### Unverändert

- Das Konsolen-Skript `Sophos-DeviceMigration.ps1` bleibt mit gleichem Funktionsumfang erhalten.

## 1.0

- Interaktives Konsolen-Skript zur Migration von Servern/Clients zwischen Sophos-Central-Tenants
  (Tenant-API-Keys oder Partner-Login, Auswahl per Out-GridView, Status-Polling pro Gerät).
