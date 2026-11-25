// Explorer-style result row: file-type icon, bold name, folder path
// underneath, snippet, size + date on the right, Open button.
import 'package:flutter/material.dart';

import '../core/models.dart';
import 'file_type.dart';

class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.result,
    required this.onOpen,
  });

  final SearchResult result;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final kind = fileKindForPath(result.path);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(fileKindIcon(kind), size: 22, color: const Color(0xFF1D1D1F)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF1D1D1F),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  result.folder,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF1D1D1F),
                  ),
                ),
                if (result.snippet.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    result.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF1D1D1F),
                    ),
                  ),
                ],
                if (result.note != null && result.note!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    result.note!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF1D1D1F),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatBytes(result.size),
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF1D1D1F),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatDate(result.mtime),
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF1D1D1F),
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: onOpen,
                child: const Text('Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
