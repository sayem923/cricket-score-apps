import '../models/models.dart';

// --- GLOBAL DATA ---
// This list is kept as an in-memory cache for convenience, but it is now
// backed by StorageService (see storage_service.dart) so tournaments survive
// an app restart - previously this list was the ONLY place the data lived
// and everything vanished when the app closed.
List<Tournament> globalTournaments = [];
bool globalTournamentsLoaded = false;