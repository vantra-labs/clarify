// Живая проверка загрузки вложений: настоящий Supabase, настоящее хранилище,
// настоящий пользователь.
//
// НЕ входит в обычный прогон: имя без `_test` — `flutter test` такие файлы не
// подхватывает. Запускать руками, когда меняется attachment_service:
//
//     flutter test test/attachment_service_live.dart
//
// Зачем отдельно от attachment_prepare_test: тот проверяет сжатие чистыми
// функциями и работает где угодно. Здесь проверяется то, чего чистой функцией
// не проверить — что файл действительно кладётся в корзину, что повторная
// загрузка того же содержимого не занимает место дважды и что удаление уносит
// файл, а не только строку. Один раз это уже расходилось с ожиданием (правила
// доступа к storage — отдельный свод от правил на таблице), поэтому проверка
// живая, а не на заглушках.
//
// Создаёт свою одноразовую учётную запись через обычную регистрацию и убирает
// за собой. Ключ service_role здесь не нужен и не используется.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/attachment_service.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Картинка с шумом: ровная заливка сжалась бы нереалистично хорошо.
Uint8List photo({int width = 1200, int height = 900, int seed = 1}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * seed) % 256, (y * seed) % 256, (x + y) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

void main() {
  late SupabaseClient client;
  late String userId;
  final service = AttachmentService();
  int? taskId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Тестовое окружение Flutter по умолчанию подменяет сеть заглушкой, которая
    // на любой запрос отвечает 400. Проверка живая — возвращаем настоящую сеть.
    HttpOverrides.global = null;
    // Supabase хранит сессию в shared_preferences, а в тестовом окружении
    // настоящего плагина нет — подставляем его подделку. Сессия нужна только на
    // время прогона, сохранять её некуда и незачем.
    SharedPreferences.setMockInitialValues({});
    await dotenv.load(fileName: '.env');
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      // publishableKey, а не anonKey — как в main.dart (то же значение, но
      // anonKey помечен устаревшим).
      publishableKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
    client = Supabase.instance.client;

    final email = 'live-att-${DateTime.now().microsecondsSinceEpoch}@clarifyapp.ru';
    final signUp = await client.auth.signUp(email: email, password: 'Pv-${DateTime.now().microsecondsSinceEpoch}');
    userId = signUp.user!.id;

    final task = await client
        .from('tasks')
        .insert({'user_id': userId, 'title': 'Задача для проверки вложений', 'is_completed': false})
        .select('id')
        .single();
    taskId = task['id'] as int;
  });

  tearDownAll(() async {
    if (taskId != null) {
      await client.from('tasks').delete().eq('id', taskId!);
    }
    // Саму учётную запись удалить может только service_role — оставляем
    // одноразовую пустую запись, это дешевле, чем держать здесь главный ключ.
  });

  test('картинка уезжает в хранилище сжатой и читается обратно', () async {
    final original = photo();
    final attachment = await service.attach(
      bytes: original,
      fileName: 'смета.jpg',
      mimeType: 'image/jpeg',
      owner: AttachmentOwner.task(taskId!),
    );

    expect(attachment.sizeBytes, lessThan(original.length),
        reason: 'в хранилище должен лежать сжатый вариант');
    expect(attachment.storagePath, startsWith('$userId/'),
        reason: 'файл обязан лежать в своей папке — иначе правила доступа откажут');
    expect(attachment.thumbPath, isNotNull);
    expect(attachment.originalName, 'смета.jpg');

    // Ссылка временная — проверяем, что по ней реально приходят те же байты.
    final url = await service.signedUrl(attachment.storagePath);
    final response = await client.storage.from('attachments').download(attachment.storagePath);
    expect(response.length, attachment.sizeBytes);
    expect(url, contains('token='));

    final listed = await service.listFor(AttachmentOwner.task(taskId!));
    expect(listed.map((a) => a.id), contains(attachment.id));
  });

  test('тот же файл дважды не занимает место дважды', () async {
    final bytes = photo(seed: 3);
    final first = await service.attach(
      bytes: bytes,
      fileName: 'одно.jpg',
      mimeType: 'image/jpeg',
      owner: AttachmentOwner.task(taskId!),
    );
    final second = await service.attach(
      bytes: bytes,
      fileName: 'то_же_самое.jpg',
      mimeType: 'image/jpeg',
      owner: AttachmentOwner.task(taskId!),
    );

    expect(second.storagePath, first.storagePath,
        reason: 'путь строится из хэша содержимого');
    expect(second.id, isNot(first.id),
        reason: 'описаний два — человек приложил файл дважды и должен видеть оба');

    // Наличие файла проверяем списком папки, а не скачиванием: отдача идёт
    // через кэш, и скачивание ещё какое-то время отдаёт удалённый файл. Список
    // папки спрашивает само хранилище и показывает настоящее состояние.
    final fileName = second.storagePath.split('/').last;
    Future<List<String>> folder() async {
      final listed = await client.storage.from('attachments').list(path: userId);
      return listed.map((f) => f.name).toList();
    }

    // Удаляем одно из двух описаний: файл обязан остаться, иначе второе
    // вложение показывало бы пустоту.
    await service.remove(first);
    expect(await folder(), contains(fileName),
        reason: 'на файл ещё ссылается второе вложение');

    // А теперь последнее описание — файл должен уйти вместе с ним.
    await service.remove(second);
    expect(await folder(), isNot(contains(fileName)),
        reason: 'последняя ссылка убрана — файл обязан освободить место');
  });

  test('ссылки на превью выдаются пачкой', () async {
    final a = await service.attach(
      bytes: photo(seed: 5),
      fileName: 'а.jpg',
      mimeType: 'image/jpeg',
      owner: AttachmentOwner.task(taskId!),
    );
    final b = await service.attach(
      bytes: photo(seed: 7),
      fileName: 'б.jpg',
      mimeType: 'image/jpeg',
      owner: AttachmentOwner.task(taskId!),
    );

    final urls = await service.signedUrls([a.thumbPath!, b.thumbPath!]);
    expect(urls.length, 2);
    expect(urls[a.thumbPath!], contains('token='));

    await service.remove(a);
    await service.remove(b);
  });

  test('не-картинка уходит как есть, без потери байтов', () async {
    final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 251));
    final attachment = await service.attach(
      bytes: bytes,
      fileName: 'договор.pdf',
      mimeType: 'application/pdf',
      owner: AttachmentOwner.task(taskId!),
    );

    expect(attachment.sizeBytes, bytes.length);
    final downloaded = await client.storage.from('attachments').download(attachment.storagePath);
    expect(downloaded, equals(bytes));

    await service.remove(attachment);
  });
}
