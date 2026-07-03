import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:wrytte/components/post_components/post_item.dart';
import 'package:wrytte/components/post_components/video_item.dart';

// ── Dummy data ────────────────────────────────────────────────────────────────

final List<PostData> _dummyPosts = [
  const PostData(
    authorName: 'Jim Carrey',
    authorAvatarUrl: '',
    timeAgo: '2d',
    text:
        'Work like there is someone working 24 hours a day to take it away from you. #césar2026',
    isVideo: true,
    videoDuration: '0:52',
    comments: 112,
    likes: 1200,
    reposts: 267,
  ),
  const PostData(
    authorName: 'Alice Johnson',
    authorAvatarUrl: '',
    timeAgo: '3h',
    text: 'Golden hour never disappoints. 🌅 #photography',
    isVideo: false,
    comments: 45,
    likes: 893,
    reposts: 102,
  ),
  const PostData(
    authorName: 'Bob Martinez',
    authorAvatarUrl: '',
    timeAgo: '5h',
    text:
        'Just shipped a new feature after 3 weeks of debugging. The feeling is unmatched 🚀',
    isVideo: false,
    comments: 78,
    likes: 540,
    reposts: 61,
  ),
  const PostData(
    authorName: 'Carol White',
    authorAvatarUrl: '',
    timeAgo: '1d',
    text: 'Travel changes you. Every single time. ✈️ #wanderlust #travel',
    isVideo: true,
    videoDuration: '1:14',
    comments: 203,
    likes: 3400,
    reposts: 489,
  ),
  const PostData(
    authorName: 'David Kim',
    authorAvatarUrl: '',
    timeAgo: '1d',
    text: 'Hot take: dark mode is not just a preference, it\'s a lifestyle. 🌑',
    isVideo: false,
    comments: 312,
    likes: 2100,
    reposts: 774,
    isLiked: true,
  ),
  const PostData(
    authorName: 'Emma Clarke',
    authorAvatarUrl: '',
    timeAgo: '2d',
    text:
        'Morning run done ✅ 5km before sunrise hits different. #fitness #running',
    isVideo: false,
    comments: 29,
    likes: 415,
    reposts: 38,
  ),
  const PostData(
    authorName: 'Frank Osei',
    authorAvatarUrl: '',
    timeAgo: '2d',
    text:
        'The best investment you can make is in yourself. Keep learning, keep growing. 📚',
    isVideo: true,
    videoDuration: '2:05',
    comments: 187,
    likes: 4700,
    reposts: 1200,
    isSaved: true,
  ),
  const PostData(
    authorName: 'Grace Nakamura',
    authorAvatarUrl: '',
    timeAgo: '3d',
    text:
        'Cherry blossom season is finally here 🌸 Tokyo is absolutely magical right now.',
    isVideo: false,
    comments: 94,
    likes: 6200,
    reposts: 882,
  ),
  const PostData(
    authorName: 'Henry Brooks',
    authorAvatarUrl: '',
    timeAgo: '3d',
    text:
        'Built my first mechanical keyboard from scratch. Worth every penny and every hour. ⌨️',
    isVideo: true,
    videoDuration: '3:22',
    comments: 156,
    likes: 1800,
    reposts: 340,
  ),
  const PostData(
    authorName: 'Isla Fernandez',
    authorAvatarUrl: '',
    timeAgo: '4d',
    text:
        'reminder that rest is productive too. you don\'t have to earn your breaks. 💙',
    isVideo: false,
    comments: 421,
    likes: 8900,
    reposts: 2300,
    isLiked: true,
    isSaved: true,
  ),
];

final List<VideoData> _dummyVideos = [
  const VideoData(
    authorName: 'Jim Carrey',
    authorAvatarUrl: '',
    caption:
        'Work like there is someone working 24 hours a day to take it away from you. #césar2026 ...',
    thumbnailUrl: 'assets/images/video image1.jpg',
    comments: 112,
    likes: 1200,
    reposts: 267,
  ),
  const VideoData(
    authorName: 'Carol White',
    authorAvatarUrl: '',
    caption:
        'Travel changes you. Every single time. ✈️ #wanderlust #travel ...',
    thumbnailUrl: 'assets/images/video image2.jpg',
    comments: 203,
    likes: 3400,
    reposts: 489,
  ),
  const VideoData(
    authorName: 'Frank Osei',
    authorAvatarUrl: '',
    caption:
        'The best investment you can make is in yourself. Keep learning, keep growing. 📚',
    thumbnailUrl: 'assets/images/video image3.jpg',
    comments: 187,
    likes: 4700,
    reposts: 1200,
    isSaved: true,
  ),
  const VideoData(
    authorName: 'Henry Brooks',
    authorAvatarUrl: '',
    caption:
        'Built my first mechanical keyboard from scratch. Worth every penny and every hour. ⌨️',
    thumbnailUrl: 'assets/images/video image4.jpg',
    comments: 156,
    likes: 1800,
    reposts: 340,
  ),
  const VideoData(
    authorName: 'Grace Nakamura',
    authorAvatarUrl: '',
    caption: 'Cherry blossom season 🌸 Tokyo is absolutely magical right now.',
    thumbnailUrl: 'assets/images/video image5.jpg',
    comments: 94,
    likes: 6200,
    reposts: 882,
  ),
  const VideoData(
    authorName: 'Isla Fernandez',
    authorAvatarUrl: '',
    caption:
        'reminder that rest is productive too. you don\'t have to earn your breaks. 💙',
    thumbnailUrl: 'assets/images/video image1.jpg',
    comments: 421,
    likes: 8900,
    reposts: 2300,
    isLiked: true,
    isSaved: true,
  ),
];

// ── Shared glass decoration helper ───────────────────────────────────────────

BoxDecoration _glassDecoration(double borderRadius) {
  return BoxDecoration(
    color: const Color(0xFF23262C).withOpacity(0.30),
    borderRadius: BorderRadius.circular(borderRadius),
    border: Border.all(color: const Color(0xFF23262C), width: 1.0),
  );
}

// ── Screen ────────────────────────────────────────────────────────────────────

class PostScreen extends StatefulWidget {
  const PostScreen({super.key});

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _postsScrollController = ScrollController();
  final PageController _videoPageController = PageController();

  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() => _currentTab = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _postsScrollController.dispose();
    _videoPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double screenHeight = MediaQuery.of(context).size.height;

    const double kTopSpacing = 16.0;
    const double kTabRowHeight = 44.0;
    const double kBottomGap = 12.0;
    final double headerHeight =
        statusBarHeight + kTopSpacing + kTabRowHeight + kBottomGap;

    const double navPillHeight = 5.0;
    const double navBottomPadding = 4.0;
    final double videoFeedHeight =
        screenHeight - navPillHeight - navBottomPadding - bottomInset;

    final bool isVideoTab = _currentTab == 1;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Layer 1: content ──────────────────────────────────────────────
          Positioned.fill(
            child: TabBarView(
              controller: _tabController,
              // ✅ Removed NeverScrollableScrollPhysics — swipe between tabs is now enabled
              children: [
                _buildPostsFeed(headerHeight),
                Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: videoFeedHeight,
                    child: PageView.builder(
                      controller: _videoPageController,
                      scrollDirection: Axis.vertical,
                      itemCount: _dummyVideos.length,
                      itemBuilder:
                          (context, index) =>
                              VideoItem(video: _dummyVideos[index]),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Layer 2: gradient (Posts tab only) ────────────────────────────
          if (!isVideoTab)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: headerHeight + 20,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.6, 1.0],
                      colors: [
                        const Color(0xFF08090B).withOpacity(0.95),
                        const Color(0xFF08090B).withOpacity(0.75),
                        const Color(0xFF08090B).withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── Layer 3: header ───────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopBar(statusBarHeight, kTopSpacing, isVideoTab),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(
    double statusBarHeight,
    double topSpacing,
    bool isVideoTab,
  ) {
    return Padding(
      padding: EdgeInsets.only(top: statusBarHeight + topSpacing),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Balance spacer matching search button width
            const SizedBox(width: 44, height: 44),

            // ── Posts | Video pill — centered, glass effect ───────────────
            Expanded(
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.all(4),
                      decoration: _glassDecoration(24),
                      child: IntrinsicWidth(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _TabPill(
                              label: 'Posts',
                              isActive: _currentTab == 0,
                              onTap: () => _tabController.animateTo(0),
                            ),
                            _TabPill(
                              label: 'Video',
                              isActive: _currentTab == 1,
                              onTap: () => _tabController.animateTo(1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Search icon — glass effect ────────────────────────────────
            GestureDetector(
              onTap: () {},
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: _glassDecoration(22),
                    child: const Icon(
                      Icons.search,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostsFeed(double headerHeight) {
    return ListView.builder(
      controller: _postsScrollController,
      padding: EdgeInsets.only(top: headerHeight, bottom: 120),
      physics: const BouncingScrollPhysics(),
      itemCount: _dummyPosts.length,
      itemBuilder: (context, index) => PostItem(post: _dummyPosts[index]),
    );
  }
}

// ── Tab pill ──────────────────────────────────────────────────────────────────

class _TabPill extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF23262C) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.white.withOpacity(0.45),
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
