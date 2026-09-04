import 'package:flutter/material.dart';
import '../../models/models.dart';
import '../../utils/extensions.dart';
import '../../l10n/app_strings.dart';

class TournamentStatsScreen extends StatefulWidget {
  final Tournament tournament;
  const TournamentStatsScreen({super.key, required this.tournament});

  @override
  State<TournamentStatsScreen> createState() => _TournamentStatsScreenState();
}

class _TournamentStatsScreenState extends State<TournamentStatsScreen> {
  // These English strings stay as the internal lookup/sort keys (passed to
  // sortByCategory, compared against battingCats/bowlingCats) - only the
  // on-screen label is translated, via _categoryLabel below. Translating
  // the keys themselves would silently break the category switcher, since
  // sortByCategory matches on these exact English strings.
  String selectedCategory = "Most Runs";
  final List<String> battingCats = ["Most Runs", "Highest Score", "Best Average", "Best Strike Rate", "Most Hundreds", "Most Fifties", "Most Fours", "Most Sixes", "Most Nineties"];
  final List<String> bowlingCats = ["Most Wickets", "Best Bowling Average", "Best Bowling", "Most 4 Wickets", "Best Economy", "Best Bowling Strike Rate"];

  static const Map<String, String> _categoryKeyMap = {
    "Most Runs": 'cat_most_runs',
    "Highest Score": 'cat_highest_score',
    "Best Average": 'cat_best_average',
    "Best Strike Rate": 'cat_best_strike_rate',
    "Most Hundreds": 'cat_most_hundreds',
    "Most Fifties": 'cat_most_fifties',
    "Most Fours": 'cat_most_fours',
    "Most Sixes": 'cat_most_sixes',
    "Most Nineties": 'cat_most_nineties',
    "Most Wickets": 'cat_most_wickets',
    "Best Bowling Average": 'cat_best_bowling_average',
    "Best Bowling": 'cat_best_bowling',
    "Most 4 Wickets": 'cat_most_4_wickets',
    "Best Economy": 'cat_best_economy',
    "Best Bowling Strike Rate": 'cat_best_bowling_strike_rate',
  };

  String _categoryLabel(String category) {
    final key = _categoryKeyMap[category];
    return key != null ? tr(key) : category;
  }

  @override
  Widget build(BuildContext context) {
    List<PlayerStat> players = widget.tournament.playerStats.values.toList();
    players.sortByCategory(selectedCategory);

    bool isBattingCat = battingCats.contains(selectedCategory);

    // Sidebar is a slide-in Drawer (opened via the menu icon below, or by
    // swiping in from the left edge) instead of a permanently-visible
    // column, so the stats table always gets the full screen width and its
    // columns/names don't get cut off on a phone-width screen.
    return Scaffold(
      drawer: Drawer(
        // Explicit light background (matching this screen's existing
        // light-grey table styling) because the app's overall theme is
        // dark - without this, the Drawer would inherit the dark theme
        // background while the nav text stayed dark, making it unreadable.
        backgroundColor: Colors.grey.shade100,
        child: SafeArea(
          child: ListView(children: [
            _buildHeader(tr('batting_header')), ...battingCats.map((c) => _buildNavItem(c)),
            _buildHeader(tr('bowling_header')), ...bowlingCats.map((c) => _buildNavItem(c)),
          ]),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            color: const Color(0xFF00695C),
            child: Row(children: [
              Builder(builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu, color: Colors.white),
                tooltip: tr('choose_category'),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              )),
              Expanded(
                child: Text(
                  _categoryLabel(selectedCategory),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  // Explicit background + text colors throughout this table
                  // (rather than inheriting the app's theme, which is
                  // dark-mode by default). Without this, header/cell text
                  // defaults to a light color that's invisible against
                  // these light grey backgrounds.
                  dataRowColor: MaterialStateProperty.all(Colors.white),
                  headingRowColor: MaterialStateProperty.all(Colors.grey.shade200),
                  columnSpacing: 24,
                  columns: [
                    DataColumn(label: Text(tr('col_player'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataColumn(label: Text(tr('col_mat'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataColumn(label: Text(tr('col_inns'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataColumn(label: Text(isBattingCat ? tr('col_runs') : tr('col_wkts'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataColumn(label: Text(isBattingCat ? tr('col_avg') : tr('col_econ'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataColumn(label: Text(isBattingCat ? tr('col_sr') : tr('col_best'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    if (isBattingCat) ...[
                      DataColumn(label: Text(tr('col_4s'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                      DataColumn(label: Text(tr('col_6s'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    ]
                  ],
                  rows: players.map((p) => DataRow(cells: [
                    DataCell(Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00695C)))),
                    DataCell(Text("${p.matches}", style: const TextStyle(color: Colors.black87))),
                    DataCell(Text("${p.innings}", style: const TextStyle(color: Colors.black87))),
                    DataCell(Text("${isBattingCat ? p.runs : p.wickets}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                    DataCell(Text(isBattingCat ? (p.avg < 0 ? "-" : p.avg.toStringAsFixed(2)) : p.econ.toStringAsFixed(2), style: const TextStyle(color: Colors.black87))),
                    DataCell(Text(isBattingCat ? p.sr.toStringAsFixed(1) : p.bestBowling, style: const TextStyle(color: Colors.black87))),
                    if (isBattingCat) ...[
                      DataCell(Text("${p.fours}", style: const TextStyle(color: Colors.black87))),
                      DataCell(Text("${p.sixes}", style: const TextStyle(color: Colors.black87))),
                    ]
                  ])).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String title) => Padding(padding: const EdgeInsets.fromLTRB(12, 16, 8, 4), child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade600, fontSize: 13)));

  Widget _buildNavItem(String title) {
    bool isSelected = selectedCategory == title;
    return Builder(builder: (ctx) => InkWell(
      onTap: () {
        setState(() => selectedCategory = title);
        Navigator.of(ctx).pop(); // close the drawer after picking a category
      },
      child: Container(
        color: isSelected ? const Color(0xFF00695C) : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Text(
          _categoryLabel(title),
          style: TextStyle(color: isSelected ? Colors.white : Colors.black87, fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
        ),
      ),
    ));
  }
}