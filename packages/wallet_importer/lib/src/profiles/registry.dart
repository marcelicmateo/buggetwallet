import 'pbz.dart';
import 'profile.dart';
import 'revolut.dart';

/// Every bank the importer knows, in detection order: the first whose [BankProfile.detect] accepts a file maps it.
/// Revolut goes first (its header row is specific); PBZ matches a `DATUM` cell anywhere in the head.
const bankProfiles = <BankProfile>[RevolutProfile(), PbzProfile()];

/// The labels of all known banks, alphabetical, for the unknown-layout message.
String bankLabels() => (bankProfiles.map((p) => p.label).toList()..sort()).join(' or ');
