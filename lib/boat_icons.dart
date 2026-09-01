// Catalog of selectable own-ship icons (top-down artwork, bow-up native
// orientation — same convention as the original assets/img/own_ship.png).
class BoatIconOption {
  const BoatIconOption(this.id, this.label, this.grandeAsset, this.pequenoAsset);
  final String id;
  final String label;
  final String grandeAsset; // shown large in the picker
  final String pequenoAsset; // used on-screen (map, radar)
}

const List<BoatIconOption> kBoatIconOptions = [
  BoatIconOption(
    'default',
    'Dehler 47 (por defecto)',
    'assets/img/own_ship.png',
    'assets/img/own_ship.png',
  ),
  BoatIconOption(
    'hallberg-rassy-42e-ketch-1980',
    'Hallberg-Rassy 42E Ketch (1980)',
    'assets/img/boats/grande/hallberg-rassy-42e-ketch-1980.png',
    'assets/img/boats/pequeno/hallberg-rassy-42e-ketch-1980.png',
  ),
  BoatIconOption(
    'jeanneau-sun-odyssey-45-2-2000',
    'Jeanneau Sun Odyssey 45.2 (2000)',
    'assets/img/boats/grande/jeanneau-sun-odyssey-45-2-2000.png',
    'assets/img/boats/pequeno/jeanneau-sun-odyssey-45-2-2000.png',
  ),
  BoatIconOption(
    'lagoon-42-catamaran',
    'Lagoon 42 (catamarán)',
    'assets/img/boats/grande/lagoon-42-catamaran.png',
    'assets/img/boats/pequeno/lagoon-42-catamaran.png',
  ),
  BoatIconOption(
    'moody-425-centre-cockpit',
    'Moody 425 Centre Cockpit',
    'assets/img/boats/grande/moody-425-centre-cockpit.png',
    'assets/img/boats/pequeno/moody-425-centre-cockpit.png',
  ),
  BoatIconOption(
    'motora-generica-9m',
    'Motora genérica 9m',
    'assets/img/boats/grande/motora-generica-9m.png',
    'assets/img/boats/pequeno/motora-generica-9m.png',
  ),
  BoatIconOption(
    'semirrigida-9m',
    'Semirrígida 9m',
    'assets/img/boats/grande/semirrigida-9m.png',
    'assets/img/boats/pequeno/semirrigida-9m.png',
  ),
  BoatIconOption(
    'velero-dos-palos-generico',
    'Velero dos palos genérico',
    'assets/img/boats/grande/velero-dos-palos-generico.png',
    'assets/img/boats/pequeno/velero-dos-palos-generico.png',
  ),
  BoatIconOption(
    'x-yachts-x56',
    'X-Yachts X56',
    'assets/img/boats/grande/x-yachts-x56.png',
    'assets/img/boats/pequeno/x-yachts-x56.png',
  ),
];

BoatIconOption boatIconById(String? id) =>
    kBoatIconOptions.firstWhere((o) => o.id == id, orElse: () => kBoatIconOptions.first);
