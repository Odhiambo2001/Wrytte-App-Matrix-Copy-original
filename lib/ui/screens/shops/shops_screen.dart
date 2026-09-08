import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:wrytte/components/shop_components/shop_item.dart';
import 'package:wrytte/ui/screens/chats/widgets/search_bar.dart'
    as local_widgets;

// ── Constants ─────────────────────────────────────────────────────────────────

const double _kSearchBarHeight = 60.0;
const double _kCategoryBarHeight = 56.0;

const List<String> _kCategories = [
  'All',
  'Vehicles',
  'Real estate',
  'Service',
  'Electronics',
];

// ── Dummy data ────────────────────────────────────────────────────────────────

const List<ShopItemData> _dummyItems = [
  ShopItemData(
    authorName: 'John Doe',
    timeAgo: '2h ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'Mercedes Benz E 6,3 AMG\nGreat condition!!!',
    price: '\$17.000',
    meta: '2018',
    likes: 14,
    comments: 27,
    reposts: 34,
    category: 'Vehicles',
  ),
  ShopItemData(
    authorName: 'Alice Johnson',
    timeAgo: '3h ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'iPhone 15 Pro Max 256GB\nNatural Titanium, barely used',
    price: '\$980',
    meta: '2023',
    likes: 42,
    comments: 18,
    reposts: 9,
    category: 'Electronics',
    isLiked: true,
  ),
  ShopItemData(
    authorName: 'Bob Martinez',
    timeAgo: '5h ago',
    badgeLabel: 'Rent',
    badgeColor: Color(0xFF22C55E),
    title: '3-Bedroom Apartment in Downtown\nFully furnished, city view',
    price: '\$1,200/mo',
    meta: '3 rooms',
    likes: 89,
    comments: 34,
    reposts: 21,
    category: 'Real estate',
  ),
  ShopItemData(
    authorName: 'Carol White',
    timeAgo: '1d ago',
    badgeLabel: 'Service',
    badgeColor: Color(0xFFF59E0B),
    title: 'Professional Photography\nEvents, portraits, commercial',
    price: '\$150/hr',
    likes: 203,
    comments: 67,
    reposts: 45,
    category: 'Service',
    isSaved: true,
  ),
  ShopItemData(
    authorName: 'David Kim',
    timeAgo: '1d ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'BMW X5 xDrive40i\nFull option, sunroof, leather seats',
    price: '\$42.000',
    meta: '2021',
    likes: 156,
    comments: 49,
    reposts: 37,
    category: 'Vehicles',
    isLiked: true,
    isSaved: true,
  ),
  ShopItemData(
    authorName: 'Emma Clarke',
    timeAgo: '2d ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'Samsung 65" QLED 4K TV\nLike new, with stand and remote',
    price: '\$620',
    meta: '2022',
    likes: 31,
    comments: 12,
    reposts: 5,
    category: 'Electronics',
  ),
  ShopItemData(
    authorName: 'Frank Osei',
    timeAgo: '2d ago',
    badgeLabel: 'Rent',
    badgeColor: Color(0xFF22C55E),
    title: 'Cozy Studio in Westside\nAll utilities included',
    price: '\$650/mo',
    meta: '1 room',
    likes: 77,
    comments: 29,
    reposts: 14,
    category: 'Real estate',
  ),
  ShopItemData(
    authorName: 'Grace Nakamura',
    timeAgo: '3d ago',
    badgeLabel: 'Service',
    badgeColor: Color(0xFFF59E0B),
    title: 'Web Development & Design\nReact, Flutter, full-stack projects',
    price: '\$80/hr',
    likes: 94,
    comments: 41,
    reposts: 28,
    category: 'Service',
  ),
  ShopItemData(
    authorName: 'Henry Brooks',
    timeAgo: '3d ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'Toyota Land Cruiser 200\nOriginal paint, no accidents',
    price: '\$55.000',
    meta: '2019',
    likes: 188,
    comments: 73,
    reposts: 52,
    category: 'Vehicles',
    isSaved: true,
  ),
  ShopItemData(
    authorName: 'Isla Fernandez',
    timeAgo: '4d ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'MacBook Pro M3 14"\n16GB RAM, 512GB SSD',
    price: '\$1,750',
    meta: '2024',
    likes: 421,
    comments: 108,
    reposts: 77,
    category: 'Electronics',
    isLiked: true,
    isSaved: true,
  ),
  ShopItemData(
    authorName: 'James Owusu',
    timeAgo: '5d ago',
    badgeLabel: 'Rent',
    badgeColor: Color(0xFF22C55E),
    title: 'Luxury Villa with Pool\nPrivate garden, 4 bedrooms',
    price: '\$3,500/mo',
    meta: '4 rooms',
    likes: 312,
    comments: 95,
    reposts: 61,
    category: 'Real estate',
  ),
  ShopItemData(
    authorName: 'Karen Lee',
    timeAgo: '5d ago',
    badgeLabel: 'Service',
    badgeColor: Color(0xFFF59E0B),
    title: 'Personal Training & Nutrition\nOnline & in-person sessions',
    price: '\$60/session',
    likes: 145,
    comments: 56,
    reposts: 33,
    category: 'Service',
    isLiked: true,
  ),
  ShopItemData(
    authorName: 'Liam Patel',
    timeAgo: '6d ago',
    badgeLabel: 'Exchange',
    badgeColor: Color(0xFFE879F9),
    title: 'Honda Civic Type R\nWilling to exchange for SUV',
    price: '\$28.000',
    meta: '2020',
    likes: 67,
    comments: 23,
    reposts: 18,
    category: 'Vehicles',
  ),
  ShopItemData(
    authorName: 'Mia Dubois',
    timeAgo: '1w ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'Sony PlayStation 5\nDisc edition + 3 games',
    price: '\$420',
    likes: 534,
    comments: 187,
    reposts: 94,
    category: 'Electronics',
    isSaved: true,
  ),
  ShopItemData(
    authorName: 'Noah Mensah',
    timeAgo: '1w ago',
    badgeLabel: 'Sale',
    badgeColor: Color(0xFF4DA3FF),
    title: 'Commercial Office Space\nGround floor, 120 sqm, parking included',
    price: '\$280,000',
    meta: '120 sqm',
    likes: 48,
    comments: 19,
    reposts: 11,
    category: 'Real estate',
  ),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class ShopsScreen extends StatefulWidget {
  const ShopsScreen({super.key});

  @override
  State<ShopsScreen> createState() => _ShopsScreenState();
}

class _ShopsScreenState extends State<ShopsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  double _searchBarProgress = 0.0;
  int _selectedCategory = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _kCategories.length, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _selectedCategory) {
        setState(() => _selectedCategory = _tabController.index);
      }
    });
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final progress = (offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  List<ShopItemData> _itemsForCategory(int index) {
    if (index == 0) return _dummyItems;
    final label = _kCategories[index];
    return _dummyItems.where((i) => i.category == label).toList();
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double bottomNavHeight =
        80 + MediaQuery.of(context).padding.bottom + 16;

    const double topBarHeight = kToolbarHeight;
    final double headerHeight =
        statusBarHeight +
        topBarHeight +
        _kSearchBarHeight +
        _kCategoryBarHeight +
        8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientHeight = headerHeight - searchBarOffset;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: bottomNavHeight - 80, right: 0),
        child: FloatingActionButton(
          onPressed: () {},
          backgroundColor: const Color(0xFF4DA3FF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.add, color: Colors.black, size: 28),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: [
          // ── Layer 1: swipeable tab content ────────────────────────────────
          Positioned.fill(
            child: TabBarView(
              controller: _tabController,
              children: List.generate(_kCategories.length, (tabIndex) {
                final items = _itemsForCategory(tabIndex);
                return ListView.builder(
                  controller: tabIndex == 0 ? _scrollController : null,
                  padding: EdgeInsets.only(top: headerHeight, bottom: 120),
                  physics: const BouncingScrollPhysics(),
                  itemCount: items.length,
                  itemBuilder:
                      (context, index) => ShopItemCard(item: items[index]),
                );
              }),
            ),
          ),

          // ── Layer 2: gradient scrim over header ───────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: gradientHeight + 20,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.6, 1.0],
                    colors: [
                      const Color(0xFF08090B).withValues(alpha: 0.95),
                      const Color(0xFF08090B).withValues(alpha: 0.75),
                      const Color(0xFF08090B).withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Layer 3: animated header ──────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top bar — always fixed, never moves
                _ShopsTopBar(statusBarHeight: statusBarHeight),

                // Search bar — slides up and fades out as user scrolls
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: Opacity(
                    opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: _kSearchBarHeight,
                      child: local_widgets.SearchBar(),
                    ),
                  ),
                ),

                // Category bar — slides up with search bar then sticks
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: SizedBox(
                    height: _kCategoryBarHeight,
                    child: _CategoryBar(
                      tabController: _tabController,
                      selectedIndex: _selectedCategory,
                      onSelected: (i) {
                        setState(() => _selectedCategory = i);
                        _tabController.animateTo(i);
                      },
                    ),
                  ),
                ),

                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Top bar ───────────────────────────────────────────────────────────────────

class _ShopsTopBar extends StatelessWidget {
  final double statusBarHeight;

  const _ShopsTopBar({required this.statusBarHeight});

  static const double _pillHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: statusBarHeight),
      child: SizedBox(
        height: kToolbarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // ── Left & Right controls ───────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // ── Location pill ───────────────────────────────────────
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        height: _pillHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF23262C,
                          ).withValues(alpha: 0.30),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: const Color(0xFF23262C),
                            width: 1.0,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Color(0xFF4DA3FF),
                              size: 18,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Location',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── More vert pill ──────────────────────────────────────
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Container(
                        width: _pillHeight,
                        height: _pillHeight,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF23262C,
                          ).withValues(alpha: 0.30),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: const Color(0xFF23262C),
                            width: 1.0,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.more_vert,
                          color: Color(0xFF4DA3FF),
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // ── Perfectly centered title ───────────────────────────────
              const Text(
                'Shops',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Category bar ──────────────────────────────────────────────────────────────
// Uses AnimatedBuilder on TabController to animate the active indicator
// exactly like _InsetTabIndicator in TabBarSection — smooth slide transition.

class _CategoryBar extends StatelessWidget {
  final TabController tabController;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _CategoryBar({
    required this.tabController,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF23262C), width: 1.0),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: AnimatedBuilder(
              animation: tabController.animation!,
              builder: (context, _) {
                final animValue = tabController.animation!.value;
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _kCategories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 2),
                  itemBuilder: (context, index) {
                    // Compute interpolated "active weight" for this chip
                    // so the indicator slides smoothly between chips
                    final double distance = (animValue - index).abs();
                    final double activeWeight =
                        (1.0 - distance.clamp(0.0, 1.0));

                    final bool isActive = index == selectedIndex;

                    return GestureDetector(
                      onTap: () => onSelected(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOut,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isActive
                                  ? const Color(0xFF23262C)
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _kCategories[index],
                          style: TextStyle(
                            color:
                                isActive
                                    ? Colors.white
                                    : Colors.white.withValues(
                                      alpha: 0.3 + activeWeight * 0.3,
                                    ),
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
