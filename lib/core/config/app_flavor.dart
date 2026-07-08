enum AppFlavor { household, collector }

class FlavorConfig {
  static AppFlavor flavor = AppFlavor.household;

  static bool get isHousehold => flavor == AppFlavor.household;
  static bool get isCollector => flavor == AppFlavor.collector;
  static String get defaultRole => isHousehold ? 'HOUSEHOLD' : 'COLLECTOR';
  static String get appName => isHousehold ? 'SmartBins Eco' : 'SmartBins Collector';
  static String get tagline => isHousehold
      ? 'Waste collection, on demand'
      : 'Earn by collecting waste';
  static String get registerSubtitle => isHousehold
      ? 'Join SmartBins and start scheduling pickups'
      : 'Join SmartBins and start earning by collecting waste';
}
