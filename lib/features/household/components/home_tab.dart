import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design_system/household_design_system.dart';
import '../../../shared/components/smartbins_map.dart';
import '../../../shared/components/searching_radar_widget.dart';
import '../providers/household_provider.dart';
import '../screens/book_screen.dart';
import '../screens/tracking_screen.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.myPos, required this.onTabSwitch});
  final ll.LatLng? myPos;
  final ValueChanged<int> onTabSwitch;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  void _openBook({String mode = 'immediate'}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookScreen(mode: mode, myPos: widget.myPos)),
    );
  }

  void _onCollectorTap(Map<String, dynamic> collector) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CollectorBottomSheet(
        collector: collector,
        myPos: widget.myPos,
        onRequestPickup: () {
          Navigator.pop(context);
          _openBook(mode: 'immediate');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.myPos;
    final provider = context.watch<HouseholdProvider>();
    if (pos == null) {
      return const Center(child: SearchingRadarWidget(color: HouseholdColors.primary));
    }
    final active = provider.activeBooking;
    final pickupMarker = _pickupMarkerFor(active, pos);
    return Stack(
      children: [
        Positioned.fill(
          child: SmartBinsMap(
            initialPosition: pos,
            collectors: provider.onlineCollectors,
            pickupPosition: pickupMarker,
            onCollectorTap: _onCollectorTap,
          ),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 14,
          left: 18,
          right: 18,
          child: HCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            radius: 30,
            child: Row(children: [
              const HIcon('location', color: HouseholdColors.primary),
              const SizedBox(width: 12),
              Expanded(child: Text('Where should we collect?', style: HouseholdType.section)),
              const HIcon('search', color: HouseholdColors.charcoal),
            ]),
          ),
        ),
        if (provider.isSurging)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 80,
            left: 18,
            right: 18,
            child: _SurgeBanner(label: provider.surgeLabel, multiplier: provider.surgeMultiplier),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 104,
          child: _BookingPanel(
            active: active,
            onBookNow: () => _openBook(mode: 'immediate'),
            onSchedule: () => _openBook(mode: 'scheduled'),
            onHistory: () => widget.onTabSwitch(3),
            onTrack: () {
              if (active != null) {
                Navigator.push(context, MaterialPageRoute(builder: (_) => TrackingScreen(booking: active)));
              }
            },
          ),
        ),
      ],
    );
  }

  ll.LatLng? _pickupMarkerFor(Map<String, dynamic>? active, ll.LatLng userPos) {
    if (active == null) return null;
    final lat = (active['pickupLat'] as num?)?.toDouble();
    final lng = (active['pickupLng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    final distance = const ll.Distance().as(ll.LengthUnit.Meter, userPos, ll.LatLng(lat, lng));
    if (distance < 12) return null;
    return ll.LatLng(lat, lng);
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel({
    required this.active,
    required this.onBookNow,
    required this.onSchedule,
    required this.onHistory,
    required this.onTrack,
  });
  final Map<String, dynamic>? active;
  final VoidCallback onBookNow;
  final VoidCallback onSchedule;
  final VoidCallback onHistory;
  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    if (active != null) {
      final status = (active!['status'] as String? ?? 'SEARCHING').toUpperCase();
      if (status == 'PENDING' || status == 'SEARCHING') {
        return HCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const SizedBox(width: 92, height: 72, child: Center(child: SearchingRadarWidget(color: HouseholdColors.primary, size: 72))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Finding a collector...', style: HouseholdType.section),
                const SizedBox(height: 2),
                Text(active!['pickupAddress'] as String? ?? 'Matching the nearest collector now.', maxLines: 2, overflow: TextOverflow.ellipsis, style: HouseholdType.caption),
              ])),
            ]),
            const SizedBox(height: 14),
            HButton(label: 'Track pickup', icon: 'tracking', onPressed: onTrack),
          ]),
        );
      }

      final isArriving = ['ASSIGNED', 'ACCEPTED', 'EN_ROUTE', 'ON_THE_WAY', 'ARRIVED', 'COLLECTING'].contains(status);
      final isComplete = ['COMPLETED', 'COLLECTED'].contains(status);
      final asset = isComplete ? HouseholdAssets.complete : HouseholdAssets.arriving;
      final title = isComplete ? 'Pickup complete' : isArriving ? 'Collector arriving' : status.replaceAll('_', ' ');
      final copy = isComplete
          ? 'Collection done. Your receipt and impact record are ready.'
          : active!['pickupAddress'] as String? ?? 'Pickup in progress';
      return HCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            asset.endsWith('.svg')
                ? SvgPicture.asset(asset, height: 72, width: 88)
                : Image.asset(asset, height: 72, width: 88, fit: BoxFit.contain),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: HouseholdType.section),
              const SizedBox(height: 2),
              Text(copy, maxLines: 2, overflow: TextOverflow.ellipsis, style: HouseholdType.caption),
            ])),
          ]),
          const SizedBox(height: 14),
          if (!isComplete)
            HButton(label: 'Track pickup', icon: 'tracking', onPressed: onTrack)
          else
            HButton(label: 'View history', icon: 'history', secondary: true, onPressed: onHistory),
        ]),
      );
    }

    // No active booking — show two CTA cards
    return Column(mainAxisSize: MainAxisSize.min, children: [
      HCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Ready to book?', style: HouseholdType.section),
          const SizedBox(height: 4),
          Text('Select waste type, bin size, address and pay — all in one flow.', style: HouseholdType.caption),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _CtaCard(
                title: 'Request Now',
                sub: '~15 min arrival',
                icon: 'pickup',
                primary: true,
                onTap: onBookNow,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _CtaCard(
                title: 'Schedule',
                sub: 'Pick date & time',
                icon: 'calendar',
                primary: false,
                onTap: onSchedule,
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

class _CtaCard extends StatelessWidget {
  const _CtaCard({required this.title, required this.sub, required this.icon, required this.primary, required this.onTap});
  final String title;
  final String sub;
  final String icon;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: primary ? HouseholdColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: primary ? HouseholdColors.primary : const Color(0xFFE8E4DD)),
          boxShadow: primary
              ? [BoxShadow(color: HouseholdColors.primary.withAlpha(50), blurRadius: 16, offset: const Offset(0, 8))]
              : [BoxShadow(color: HouseholdColors.forest.withAlpha(12), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HIcon(icon, size: 22, color: primary ? Colors.white : HouseholdColors.primary),
          const SizedBox(height: 10),
          Text(title, style: HouseholdType.section.copyWith(color: primary ? Colors.white : HouseholdColors.charcoal, fontSize: 15)),
          const SizedBox(height: 2),
          Text(sub, style: HouseholdType.caption.copyWith(color: primary ? Colors.white.withAlpha(180) : HouseholdColors.gray)),
        ]),
      ),
    );
  }
}

// ── Collector tap bottom sheet ────────────────────────────────────────────────
class _CollectorBottomSheet extends StatelessWidget {
  const _CollectorBottomSheet({required this.collector, required this.onRequestPickup, this.myPos});
  final Map<String, dynamic> collector;
  final VoidCallback onRequestPickup;
  final ll.LatLng? myPos;

  double? _distanceKm() {
    final lat = (collector['lastLat'] as num?)?.toDouble();
    final lng = (collector['lastLng'] as num?)?.toDouble();
    if (lat == null || lng == null || myPos == null) return null;
    return const ll.Distance().as(ll.LengthUnit.Kilometer, myPos!, ll.LatLng(lat, lng));
  }

  @override
  Widget build(BuildContext context) {
    final name = collector['fullName'] as String? ?? collector['name'] as String? ?? 'Collector';
    final phone = collector['phone'] as String?;
    final rating = (collector['rating'] as num?)?.toDouble() ?? (collector['ratingAverage'] as num?)?.toDouble();
    final vehicle = collector['vehicleType'] as String?;
    final dist = _distanceKm();
    final initials = name.trim().split(' ').map((w) => w.isNotEmpty ? w[0].toUpperCase() : '').take(2).join();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: HouseholdColors.forest.withAlpha(40), blurRadius: 40, offset: const Offset(0, -12))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 4,
            margin: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(color: const Color(0xFFE1DDD5), borderRadius: BorderRadius.circular(4)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: HouseholdColors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Center(child: Text(initials, style: HouseholdType.title.copyWith(color: Colors.white, fontSize: 20))),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: HouseholdType.title),
                    const SizedBox(height: 4),
                    if (rating != null && rating > 0)
                      Row(children: [
                        ...List.generate(5, (i) => Icon(
                          i < rating.floor() ? PhosphorIcons.star(PhosphorIconsStyle.fill) : PhosphorIcons.star(),
                          size: 14,
                          color: HouseholdColors.warning,
                        )),
                        const SizedBox(width: 6),
                        Text(rating.toStringAsFixed(1), style: HouseholdType.caption.copyWith(fontWeight: FontWeight.w700)),
                      ])
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: HouseholdColors.ecoGreen.withAlpha(22), borderRadius: BorderRadius.circular(99)),
                        child: Text('New', style: HouseholdType.caption.copyWith(color: HouseholdColors.ecoGreen, fontWeight: FontWeight.w700)),
                      ),
                  ])),
                  const HIcon('chevron_right', color: HouseholdColors.gray),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  if (vehicle != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: HouseholdColors.primary.withAlpha(18), borderRadius: BorderRadius.circular(12)),
                      child: Text(_vehicleLabel(vehicle), style: HouseholdType.caption.copyWith(color: HouseholdColors.primary, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                  ],
                  if (dist != null) ...[
                    const HIcon('location', color: HouseholdColors.gray, size: 16),
                    const SizedBox(width: 4),
                    Text('${dist.toStringAsFixed(1)} km', style: HouseholdType.caption),
                    const SizedBox(width: 10),
                    const HIcon('clock', color: HouseholdColors.gray, size: 16),
                    const SizedBox(width: 4),
                    Text('~${(dist / 0.4).round()} min', style: HouseholdType.caption),
                  ],
                ]),
                const SizedBox(height: 20),
                const Divider(color: Color(0xFFE8E4DD)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: phone != null
                          ? () => launchUrl(Uri.parse('tel:$phone'))
                          : null,
                      icon: Icon(PhosphorIcons.phone(), size: 18),
                      label: const Text('Call'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: HouseholdColors.forest,
                        side: const BorderSide(color: Color(0xFFE8E4DD)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: HButton(label: 'Request Pickup', icon: 'pickup', onPressed: onRequestPickup),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _vehicleLabel(String type) {
    return switch (type.toUpperCase()) {
      'PICKUP_TRUCK' => 'Pickup Truck',
      'TIPPER' || 'TIPPER_TRUCK' => 'Tipper',
      'TRICYCLE' => 'Tricycle',
      'MOTORBIKE' => 'Motorbike',
      'VAN' => 'Van',
      _ => type,
    };
  }
}

// _CategoryChip and _Selector removed — booking is now handled by BookScreen wizard

// ── Surge demand banner ───────────────────────────────────────────────────────
class _SurgeBanner extends StatelessWidget {
  const _SurgeBanner({required this.label, required this.multiplier});
  final String label;
  final double multiplier;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: HouseholdColors.warning.withAlpha(28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: HouseholdColors.warning.withAlpha(110)),
      ),
      child: Row(children: [
        Icon(PhosphorIcons.lightning(PhosphorIconsStyle.fill), size: 18, color: HouseholdColors.warning),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: HouseholdType.caption.copyWith(
                color: HouseholdColors.charcoal, fontWeight: FontWeight.w700)),
            Text('Prices are higher right now', style: HouseholdType.caption.copyWith(
                color: HouseholdColors.gray, fontSize: 11)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: HouseholdColors.warning,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text('${multiplier.toStringAsFixed(1)}×', style: HouseholdType.number.copyWith(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      ]),
    );
  }
}
