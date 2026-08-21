import 'package:bmsc/model/release.dart';
import 'package:flutter/material.dart';

class UpdateService {
  static final Future<UpdateService> instance = Future.value(UpdateService());

  List<ReleaseResult>? newVersionInfo;
  bool hasNewVersion = false;
  String? curVersion;

  static Future<List<ReleaseResult>?> checkNewVersion() async {
    return null;
  }

  void showUpdateDialog(BuildContext context, String curVersion) {
  }
}
