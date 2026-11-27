/// مشروع Firebase اللي بيربط فروع المحل الواحد ببعض (نفس مشروع FixTrack لحد ما Basket ياخد مشروع لوحده).
/// المفتاح ده عام ومعمول يتحط في التطبيقات؛ الحماية الحقيقية في قواعد Firestore (firebase/firestore.rules).
const firebaseProjectId = 'fixtrack-7fcf9';
/// المفتاح مش مكتوب في الكود: بييجي وقت البناء من config/firebase.json (متجاهل في git):
///   flutter build ... --dart-define-from-file=config/firebase.json
const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
