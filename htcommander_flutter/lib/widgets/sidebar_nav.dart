import 'package:flutter/material.dart';

class SidebarDestination {
  const SidebarDestination({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

const List<SidebarDestination> sidebarDestinations = [
  SidebarDestination(icon: Icons.cell_tower, label: 'Communication'),
  SidebarDestination(icon: Icons.people, label: 'Contacts'),
  SidebarDestination(icon: Icons.menu_book, label: 'Logbook'),
  SidebarDestination(icon: Icons.inventory_2, label: 'Packets'),
  SidebarDestination(icon: Icons.terminal, label: 'Terminal'),
  SidebarDestination(icon: Icons.forum, label: 'BBS'),
  SidebarDestination(icon: Icons.mail, label: 'Mail'),
  SidebarDestination(icon: Icons.save, label: 'Torrent'),
  SidebarDestination(icon: Icons.satellite_alt, label: 'APRS'),
  SidebarDestination(icon: Icons.map, label: 'Map'),
  SidebarDestination(icon: Icons.bug_report, label: 'Debug'),
];

class SidebarNav extends StatelessWidget {
  const SidebarNav({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.onSettingsTap,
    this.onAboutTap,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onAboutTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: 220,
      color: colors.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
            child: Text(
              'OPERATOR',
              style: textTheme.titleSmall?.copyWith(
                color: colors.primary,
                letterSpacing: 2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              'SIGNAL STABLE',
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 1,
              ),
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: sidebarDestinations.length,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemBuilder: (context, index) {
                final dest = sidebarDestinations[index];
                final isSelected = index == selectedIndex;

                return _NavItem(
                  icon: dest.icon,
                  label: dest.label,
                  isSelected: isSelected,
                  onTap: () => onDestinationSelected(index),
                );
              },
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _NavItem(
            icon: Icons.settings,
            label: 'Settings',
            isSelected: false,
            onTap: onSettingsTap,
          ),
          _NavItem(
            icon: Icons.info_outline,
            label: 'About',
            isSelected: false,
            onTap: onAboutTap,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isSelected
                ? colors.primaryContainer.withAlpha(51)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: isSelected ? colors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                icon,
                size: 20,
                color: isSelected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? colors.onSurface : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
