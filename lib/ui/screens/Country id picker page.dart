// This legacy route is referenced by its historical filename in deep links.
// ignore_for_file: file_names

import 'package:flutter/material.dart';
import 'package:wrytte/utils/countries_id.dart';

class CountryIdPickerPage extends StatefulWidget {
  const CountryIdPickerPage({super.key});

  @override
  State<CountryIdPickerPage> createState() => _CountryIdPickerPageState();
}

class _CountryIdPickerPageState extends State<CountryIdPickerPage> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  static final List<CountryId> _allCountries = [
    ...countriesId.where((country) => country.isoCode != 'WID'),
  ];
  late List<CountryId> _filtered;
  double _searchBarProgress = 0.0;

  static const double _kSearchBarHeight = 60.0;

  @override
  void initState() {
    super.initState();
    _filtered = _allCountries;
    _search.addListener(_applyFilter);
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final progress = (offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  void _applyFilter() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() => _filtered = _allCountries);
      return;
    }

    final results =
        _allCountries
            .where(
              (c) =>
                  c.name.toLowerCase().contains(q) ||
                  c.isoCode.toLowerCase().contains(q) ||
                  c.dialCode.contains(q),
            )
            .toList();

    setState(() => _filtered = results);
  }

  /// Renders either an asset-image flag (Wrytte ID) or an emoji flag string.
  Widget _buildFlag(CountryId c) {
    if (c.isoCode == 'WID') {
      return Image.asset(c.flag, width: 28, height: 28, fit: BoxFit.contain);
    }
    return Text(c.flag, style: const TextStyle(fontSize: 22));
  }

  @override
  void dispose() {
    _search.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;

    final double headerHeight =
        statusBarHeight + kToolbarHeight + _kSearchBarHeight + 8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientHeight = headerHeight - searchBarOffset;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Layer 1: list ─────────────────────────────────────────────────
          Positioned.fill(
            child: ListView.separated(
              controller: _scrollController,
              padding: EdgeInsets.only(top: headerHeight, bottom: 32),
              physics: const BouncingScrollPhysics(),
              itemCount: _filtered.length,
              separatorBuilder:
                  (_, __) => const Divider(height: 1, color: Colors.white12),
              itemBuilder: (context, i) {
                final c = _filtered[i];
                return ListTile(
                  leading: _buildFlag(c),
                  title: Text(
                    c.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: Text(
                    '+${c.dialCode}',
                    style: const TextStyle(
                      color: Color(0xFF4DA3FF),
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, c),
                );
              },
            ),
          ),

          // ── Layer 2: single gradient over the visible header area ─────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: gradientHeight,
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

          // ── Layer 3: floating header ──────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top bar — always fixed
                _buildTopBar(statusBarHeight),

                // Search bar — slides up and fades with scroll
                Transform.translate(
                  offset: Offset(0, -searchBarOffset),
                  child: Opacity(
                    opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                    child: SizedBox(
                      height: _kSearchBarHeight,
                      child: _buildSearchBar(),
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

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar(double statusBarHeight) {
    return SizedBox(
      height: statusBarHeight + kToolbarHeight,
      child: Padding(
        padding: EdgeInsets.only(top: statusBarHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // iOS-style back button in pill container
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1013),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.chevron_left,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),

              // Centered title
              const Expanded(
                child: Center(
                  child: Text(
                    'Choose a country',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

              // Invisible spacer to balance back button
              const SizedBox(width: 36),
            ],
          ),
        ),
      ),
    );
  }

  // ── Search bar ────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF23262C),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            TextField(
              controller: _search,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            if (_search.text.isEmpty)
              IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.search, color: Colors.grey, size: 18),
                    SizedBox(width: 6),
                    Text(
                      'Search',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
