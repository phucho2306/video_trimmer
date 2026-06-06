import 'dart:io';
import 'package:example/preview.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_trimmer/video_trimmer.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final VideoEditorController _videoEditorController;

  @override
  void initState() {
    super.initState();
    _videoEditorController = VideoEditorController(
      onDeviceTrimSaved: (trimContext, outputPath) {
        debugPrint('DEVICE TRIM SAVED: path=$outputPath');
        if (outputPath == null) return;
        Navigator.pushReplacement(
          trimContext,
          MaterialPageRoute(
            builder: (_) => Preview(outputPath),
          ),
        );
      },
      onServerTrimRequest: (sourcePath, startValue, endValue) {
        debugPrint(
          'SERVER TRIM REQUEST: path=$sourcePath, '
          'start=$startValue, end=$endValue',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Video Trimmer"),
      ),
      body: Center(
        child: ElevatedButton(
          child: const Text("LOAD VIDEO"),
          onPressed: () async {
            FilePickerResult? result = await FilePicker.platform.pickFiles(
              type: FileType.video,
            );
            if (result != null) {
              if (!context.mounted) return;
              File file = File(result.files.single.path!);
              _videoEditorController.start(context, file);
            }
          },
        ),
      ),
    );
  }
}
