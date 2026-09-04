// Round-trip (toJson -> fromJson) tests for the core scorecard models.
//
// Why this matters: a match gets saved locally (offline), then synced to
// Supabase, then loaded back into the app - each hop goes through
// toJson/fromJson. If any field silently drops during that round-trip,
// the person only finds out when a finished match's scorecard comes back
// wrong, days later. These tests catch that immediately instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:cricket_score_apps/models/models.dart';

void main() {
  group('Batsman round-trip', () {
    test('every field survives toJson -> fromJson unchanged', () {
      final original = Batsman(
        name: 'Rahim',
        id: 'p1',
        runs: 87,
        balls: 65,
        fours: 9,
        sixes: 2,
        dismissal: 'c Karim b Sohel',
      );

      final restored = Batsman.fromJson(original.toJson());

      expect(restored.name, original.name);
      expect(restored.id, original.id);
      expect(restored.runs, original.runs);
      expect(restored.balls, original.balls);
      expect(restored.fours, original.fours);
      expect(restored.sixes, original.sixes);
      expect(restored.dismissal, original.dismissal);
    });
  });

  group('Bowler round-trip', () {
    test('every field survives toJson -> fromJson unchanged', () {
      final original = Bowler(name: 'Sohel', id: 'b1', runs: 34, wickets: 3, balls: 24, maidens: 1);

      final restored = Bowler.fromJson(original.toJson());

      expect(restored.name, original.name);
      expect(restored.id, original.id);
      expect(restored.runs, original.runs);
      expect(restored.wickets, original.wickets);
      expect(restored.balls, original.balls);
      expect(restored.maidens, original.maidens);
    });

    test('missing "maidens" key (old saved data) defaults to 0, not a crash', () {
      final json = {'name': 'Sohel', 'id': 'b1', 'runs': 10, 'wickets': 1, 'balls': 12};
      final restored = Bowler.fromJson(json);
      expect(restored.maidens, 0);
    });
  });

  group('Delivery round-trip', () {
    test('every field including wicket/dismissal info survives unchanged', () {
      final original = Delivery(
        batsmanId: 'bat1',
        batsmanName: 'Rahim',
        bowlerId: 'bowl1',
        bowlerName: 'Sohel',
        runsOffBat: 4,
        countsAsBallFaced: true,
        isWicket: true,
        dismissedPlayerId: 'bat1',
        bowlerCreditedWicket: true,
      );

      final restored = Delivery.fromJson(original.toJson());

      expect(restored.batsmanId, original.batsmanId);
      expect(restored.bowlerId, original.bowlerId);
      expect(restored.runsOffBat, original.runsOffBat);
      expect(restored.countsAsBallFaced, original.countsAsBallFaced);
      expect(restored.isWicket, original.isWicket);
      expect(restored.dismissedPlayerId, original.dismissedPlayerId);
      expect(restored.bowlerCreditedWicket, original.bowlerCreditedWicket);
    });

    test('a plain dot ball (no wicket) round-trips with defaults intact', () {
      final original = Delivery(
        batsmanId: 'bat1',
        batsmanName: 'Rahim',
        bowlerId: 'bowl1',
        bowlerName: 'Sohel',
        runsOffBat: 0,
        countsAsBallFaced: true,
      );

      final restored = Delivery.fromJson(original.toJson());

      expect(restored.isWicket, false);
      expect(restored.dismissedPlayerId, isNull);
      expect(restored.bowlerCreditedWicket, false);
    });
  });

  group('PlayerStat round-trip', () {
    test('every field survives toJson -> fromJson unchanged', () {
      final original = PlayerStat(name: 'Rahim')
        ..matches = 12
        ..innings = 11
        ..notOuts = 2
        ..runs = 456
        ..balls = 389
        ..fours = 40
        ..sixes = 12
        ..hundreds = 1
        ..fifties = 3
        ..nineties = 1
        ..highestScore = 102
        ..wickets = 5
        ..runsConceded = 210
        ..oversBowled = 38.2
        ..fourWickets = 1
        ..bbWickets = 4
        ..bbRuns = 22;

      final restored = PlayerStat.fromJson(original.toJson());

      expect(restored.matches, original.matches);
      expect(restored.innings, original.innings);
      expect(restored.notOuts, original.notOuts);
      expect(restored.runs, original.runs);
      expect(restored.balls, original.balls);
      expect(restored.fours, original.fours);
      expect(restored.sixes, original.sixes);
      expect(restored.hundreds, original.hundreds);
      expect(restored.fifties, original.fifties);
      expect(restored.nineties, original.nineties);
      expect(restored.highestScore, original.highestScore);
      expect(restored.wickets, original.wickets);
      expect(restored.runsConceded, original.runsConceded);
      expect(restored.oversBowled, original.oversBowled);
      expect(restored.fourWickets, original.fourWickets);
      expect(restored.bbWickets, original.bbWickets);
      expect(restored.bbRuns, original.bbRuns);
    });
  });

  group('MatchResultData round-trip', () {
    test('nested batsmen/bowlers/deliveries all survive together', () {
      final original = MatchResultData(
        winner: 'Team A',
        margin: '10 runs',
        allBatsmen: [Batsman(name: 'Rahim', id: 'p1', runs: 55, balls: 40)],
        allBowlers: [Bowler(name: 'Sohel', id: 'b1', wickets: 2, runs: 30, balls: 24)],
        fullSquad: [Player(name: 'Rahim', id: 'p1'), Player(name: 'Sohel', id: 'b1')],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '150/4',
        innings2Score: '140/8',
        isComplete: true,
        deliveries: [
          Delivery(
            batsmanId: 'p1',
            batsmanName: 'Rahim',
            bowlerId: 'b1',
            bowlerName: 'Sohel',
            runsOffBat: 4,
            countsAsBallFaced: true,
          ),
        ],
      );

      final restored = MatchResultData.fromJson(original.toJson());

      expect(restored.winner, original.winner);
      expect(restored.allBatsmen.length, 1);
      expect(restored.allBatsmen.first.runs, 55);
      expect(restored.allBowlers.length, 1);
      expect(restored.allBowlers.first.wickets, 2);
      expect(restored.deliveries.length, 1);
      expect(restored.deliveries.first.runsOffBat, 4);
      expect(restored.isComplete, true);
    });

    test('an incomplete (exited-early) match round-trips isComplete = false', () {
      final original = MatchResultData(
        winner: '',
        margin: '',
        allBatsmen: const [],
        allBowlers: const [],
        fullSquad: const [],
        teamName1: 'Team A',
        teamName2: 'Team B',
        innings1Score: '80/3',
        innings2Score: '',
        isComplete: false,
      );

      final restored = MatchResultData.fromJson(original.toJson());

      expect(restored.isComplete, false);
    });
  });
}