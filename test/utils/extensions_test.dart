// Unit tests for lib/utils/extensions.dart.
//
// Run just this file:   flutter test test/utils/extensions_test.dart
// Run everything:       flutter test
//
// Why this file first: every getter tested here (avg, sr, econ, ...) is
// pure math with no UI, no network, no Supabase - the fastest, highest-
// value place to catch a scoring mistake before it ships. If any of these
// tests fail after a change, a real match's numbers would have been wrong.
import 'package:flutter_test/flutter_test.dart';
import 'package:cricket_score_apps/models/models.dart';
import 'package:cricket_score_apps/utils/extensions.dart';

void main() {
  group('PlayerStatMetrics.avg (batting average)', () {
    test('no innings played yet -> -1 (caller shows "-")', () {
      final p = PlayerStat(name: 'A');
      expect(p.avg, -1);
    });

    test('never dismissed (all not-outs) -> average equals total runs', () {
      final p = PlayerStat(name: 'A')
        ..innings = 3
        ..notOuts = 3
        ..runs = 150;
      expect(p.avg, 150.0);
    });

    test('normal case: runs / times dismissed', () {
      final p = PlayerStat(name: 'A')
        ..innings = 4
        ..notOuts = 1
        ..runs = 120; // dismissed 3 times
      expect(p.avg, closeTo(40.0, 0.001));
    });
  });

  group('PlayerStatMetrics.sr (batting strike rate)', () {
    test('zero balls faced -> 0.0, not a divide-by-zero crash', () {
      final p = PlayerStat(name: 'A')..balls = 0;
      expect(p.sr, 0.0);
    });

    test('50 runs off 50 balls -> strike rate 100', () {
      final p = PlayerStat(name: 'A')
        ..runs = 50
        ..balls = 50;
      expect(p.sr, closeTo(100.0, 0.001));
    });
  });

  group('PlayerStatMetrics.econ (bowling economy)', () {
    test('zero overs bowled -> 0.0, not a divide-by-zero crash', () {
      final p = PlayerStat(name: 'A')..oversBowled = 0;
      expect(p.econ, 0.0);
    });

    test('24 runs in 4 overs -> economy 6.0', () {
      final p = PlayerStat(name: 'A')
        ..runsConceded = 24
        ..oversBowled = 4;
      expect(p.econ, closeTo(6.0, 0.001));
    });
  });

  group('PlayerStatMetrics.bowlSr / bowlAvg', () {
    test('zero wickets -> both 0.0, not a divide-by-zero crash', () {
      final p = PlayerStat(name: 'A')..wickets = 0;
      expect(p.bowlSr, 0.0);
      expect(p.bowlAvg, 0.0);
    });

    test('3 wickets for 30 runs off 10 overs', () {
      final p = PlayerStat(name: 'A')
        ..wickets = 3
        ..runsConceded = 30
        ..oversBowled = 10;
      expect(p.bowlAvg, closeTo(10.0, 0.001)); // 30/3
      expect(p.bowlSr, closeTo(20.0, 0.001)); // (10*6)/3
    });
  });

  group('BatsmanLogic.sr', () {
    test('zero balls -> "0.0" string, not a crash', () {
      final b = Batsman(name: 'A', id: '1', balls: 0);
      expect(b.sr, '0.0');
    });

    test('formats to one decimal place', () {
      final b = Batsman(name: 'A', id: '1', runs: 33, balls: 40);
      expect(b.sr, '82.5');
    });
  });

  group('BowlerLogic.oversDisplay', () {
    test('exact overs (e.g. 24 balls) -> "4.0"', () {
      final bo = Bowler(name: 'A', id: '1', balls: 24);
      expect(bo.oversDisplay, '4.0');
    });

    test('partial over (e.g. 25 balls) -> "4.1"', () {
      final bo = Bowler(name: 'A', id: '1', balls: 25);
      expect(bo.oversDisplay, '4.1');
    });

    test('zero balls -> "0.0"', () {
      final bo = Bowler(name: 'A', id: '1', balls: 0);
      expect(bo.oversDisplay, '0.0');
    });
  });

  group('BowlerLogic.economy', () {
    test('zero balls bowled -> "0.00", not a divide-by-zero crash', () {
      final bo = Bowler(name: 'A', id: '1', balls: 0, runs: 0);
      expect(bo.economy, '0.00');
    });

    test('24 runs off 24 balls (4 overs) -> "6.00"', () {
      final bo = Bowler(name: 'A', id: '1', balls: 24, runs: 24);
      expect(bo.economy, '6.00');
    });

    test('7 runs off 5 balls -> rounds to two decimals', () {
      final bo = Bowler(name: 'A', id: '1', balls: 5, runs: 7);
      // (7*6)/5 = 8.4
      expect(bo.economy, '8.40');
    });
  });

  group('PlayerStatMerge.mergeWith (career stat merge)', () {
    test('sums cumulative fields from both players', () {
      final a = PlayerStat(name: 'A')
        ..matches = 5
        ..runs = 200
        ..wickets = 3;
      final b = PlayerStat(name: 'A (dup)')
        ..matches = 3
        ..runs = 100
        ..wickets = 2;

      a.mergeWith(b);

      expect(a.matches, 8);
      expect(a.runs, 300);
      expect(a.wickets, 5);
    });

    test('highestScore keeps the max, not the sum', () {
      final a = PlayerStat(name: 'A')..highestScore = 87;
      final b = PlayerStat(name: 'A (dup)')..highestScore = 102;

      a.mergeWith(b);

      expect(a.highestScore, 102);
    });

    test('bestBowling keeps more wickets, tie-broken by fewer runs', () {
      final a = PlayerStat(name: 'A')
        ..bbWickets = 3
        ..bbRuns = 20;
      final b = PlayerStat(name: 'A (dup)')
        ..bbWickets = 5
        ..bbRuns = 40;

      a.mergeWith(b);

      expect(a.bbWickets, 5);
      expect(a.bbRuns, 40);
    });

    test('bestBowling tie on wickets keeps fewer runs conceded', () {
      final a = PlayerStat(name: 'A')
        ..bbWickets = 4
        ..bbRuns = 30;
      final b = PlayerStat(name: 'A (dup)')
        ..bbWickets = 4
        ..bbRuns = 18;

      a.mergeWith(b);

      expect(a.bbWickets, 4);
      expect(a.bbRuns, 18); // fewer runs for the same wicket count wins
    });
  });

  group('MatchResultStatDeltas.computePlayerStatDeltas', () {
    test('one batsman scoring a half-century gets a fifty, not a hundred', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [Batsman(name: 'Rahim', id: 'p1', runs: 55, balls: 40, dismissal: 'bowled')],
        allBowlers: [],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
      );

      final deltas = match.computePlayerStatDeltas();

      expect(deltas['p1']!.fifties, 1);
      expect(deltas['p1']!.hundreds, 0);
      expect(deltas['p1']!.runs, 55);
    });

    test('not-out batsman counts as an innings but not a dismissal', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '5 wickets',
        allBatsmen: [Batsman(name: 'Karim', id: 'p1', runs: 30, balls: 25, dismissal: 'not out')],
        allBowlers: [],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '151/5',
      );

      final deltas = match.computePlayerStatDeltas();

      expect(deltas['p1']!.innings, 1);
      expect(deltas['p1']!.notOuts, 1);
    });

    test('bowler taking 4 wickets increments fourWickets tally', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '20 runs',
        allBatsmen: [],
        allBowlers: [Bowler(name: 'Sohel', id: 'b1', wickets: 4, runs: 22, balls: 24)],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '130/10',
      );

      final deltas = match.computePlayerStatDeltas();

      expect(deltas['b1']!.fourWickets, 1);
      expect(deltas['b1']!.wickets, 4);
      expect(deltas['b1']!.bbWickets, 4);
      expect(deltas['b1']!.bbRuns, 22);
    });

    test('every player in the match gets matches = 1', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [Batsman(name: 'A', id: 'p1'), Batsman(name: 'B', id: 'p2')],
        allBowlers: [Bowler(name: 'C', id: 'p3')],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
      );

      final deltas = match.computePlayerStatDeltas();

      expect(deltas['p1']!.matches, 1);
      expect(deltas['p2']!.matches, 1);
      expect(deltas['p3']!.matches, 1);
    });
  });

  group('MatchResultMatchups.computeMatchupDeltas', () {
    test('wide does not count as a ball faced but runs still count', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [],
        allBowlers: [],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
        deliveries: [
          Delivery(
            batsmanId: 'bat1',
            batsmanName: 'Rahim',
            bowlerId: 'bowl1',
            bowlerName: 'Sohel',
            runsOffBat: 1, // 1 run byes off the wide
            countsAsBallFaced: false, // it's a wide
          ),
        ],
      );

      final matchups = match.computeMatchupDeltas();
      final entry = matchups[('bat1', 'bowl1')]!;

      expect(entry.balls, 0, reason: 'a wide must not count as a ball faced');
      expect(entry.runs, 1);
    });

    test('a run-out is not credited to the bowler as a dismissal', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [],
        allBowlers: [],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
        deliveries: [
          Delivery(
            batsmanId: 'bat1',
            batsmanName: 'Rahim',
            bowlerId: 'bowl1',
            bowlerName: 'Sohel',
            runsOffBat: 1,
            countsAsBallFaced: true,
            isWicket: true,
            dismissedPlayerId: 'bat2', // non-striker run out, not the facer
            bowlerCreditedWicket: false,
          ),
        ],
      );

      final matchups = match.computeMatchupDeltas();
      final entry = matchups[('bat1', 'bowl1')]!;

      expect(entry.dismissals, 0);
    });

    test('a clean bowled IS credited as a bowler-batsman dismissal', () {
      final match = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [],
        allBowlers: [],
        fullSquad: [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
        deliveries: [
          Delivery(
            batsmanId: 'bat1',
            batsmanName: 'Rahim',
            bowlerId: 'bowl1',
            bowlerName: 'Sohel',
            runsOffBat: 0,
            countsAsBallFaced: true,
            isWicket: true,
            dismissedPlayerId: 'bat1',
            bowlerCreditedWicket: true,
          ),
        ],
      );

      final matchups = match.computeMatchupDeltas();
      final entry = matchups[('bat1', 'bowl1')]!;

      expect(entry.dismissals, 1);
    });
  });

  group('StatSorting.sortByCategory', () {
    test('"Most Runs" sorts descending by runs', () {
      final list = [
        PlayerStat(name: 'A')..runs = 50,
        PlayerStat(name: 'B')..runs = 120,
        PlayerStat(name: 'C')..runs = 80,
      ];

      list.sortByCategory('Most Runs');

      expect(list.map((p) => p.name).toList(), ['B', 'C', 'A']);
    });

    test('"Best Economy" pushes players with 0 overs bowled to the bottom', () {
      final list = [
        PlayerStat(name: 'NeverBowled'), // oversBowled = 0
        PlayerStat(name: 'Economical')
          ..oversBowled = 4
          ..runsConceded = 12, // econ 3.0
        PlayerStat(name: 'Expensive')
          ..oversBowled = 4
          ..runsConceded = 40, // econ 10.0
      ];

      list.sortByCategory('Best Economy');

      expect(list.map((p) => p.name).toList(), ['Economical', 'Expensive', 'NeverBowled']);
    });
  });
}