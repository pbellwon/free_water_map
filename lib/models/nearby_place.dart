class NearbyPlace {
  const NearbyPlace({
    required this.name,
    required this.address,
    required this.distanceMeters,
  });

  final String name;
  final String address;
  final double distanceMeters;
}