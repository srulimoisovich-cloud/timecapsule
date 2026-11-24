<?php
// Вложения капсул лежат в S3: uploads/<случайное имя>. Остальное приложение знает только
// три функции: storage_save(), storage_delete(), storage_stream().
// Учётные данные SDK берёт сам: роль сервера timecapsule-dev-app-role (ключей в .env нет).

const STORAGE_LINK_TTL = 300; // секунд: ссылка на скачивание живёт 5 минут

function s3(): Aws\S3\S3Client
{
    static $client = null;
    return $client ??= new Aws\S3\S3Client([
        'version' => 'latest',
        'region'  => config('AWS_REGION', 'eu-central-1'),
    ]);
}

function s3_bucket(): string
{
    return config('S3_BUCKET');
}

// Кладёт файл из $_FILES в бакет, возвращает случайное имя (оно же хвост ключа).
function storage_save(array $uploadedFile, string $extension): string
{
    $name = bin2hex(random_bytes(12)) . '.' . $extension;

    s3()->putObject([
        'Bucket'      => s3_bucket(),
        'Key'         => 'uploads/' . $name,
        'SourceFile'  => $uploadedFile['tmp_name'],
        'ContentType' => mime_content_type($uploadedFile['tmp_name']),
    ]);
    return $name;
}

function storage_delete(?string $storedName): void
{
    if ($storedName === null || $storedName === '') {
        return;
    }
    s3()->deleteObject(['Bucket' => s3_bucket(), 'Key' => 'uploads/' . basename($storedName)]);
}

// Подписанная ссылка на объект. $disposition: "inline" (показать) или "attachment" (скачать).
function storage_url(string $storedName, string $mime, string $downloadName, string $disposition): string
{
    $ascii = preg_replace('/[^A-Za-z0-9._ -]/', '_', $downloadName);

    $cmd = s3()->getCommand('GetObject', [
        'Bucket'                     => s3_bucket(),
        'Key'                        => 'uploads/' . basename($storedName),
        'ResponseContentType'        => $mime,
        'ResponseContentDisposition' => sprintf(
            '%s; filename="%s"; filename*=UTF-8\'\'%s', $disposition, $ascii, rawurlencode($downloadName)
        ),
    ]);
    return (string) s3()->createPresignedRequest($cmd, '+' . STORAGE_LINK_TTL . ' seconds')->getUri();
}

// Вместо отдачи файла: 302 на подписанную ссылку. Права на капсулу проверил вызывающий код.
function storage_stream(string $storedName, string $mime, string $downloadName, string $disposition): void
{
    header('Location: ' . storage_url($storedName, $mime, $downloadName, $disposition), true, 302);
    header('Cache-Control: no-store');
}
