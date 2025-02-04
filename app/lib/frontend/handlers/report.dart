// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:_pub_shared/data/account_api.dart';
import 'package:clock/clock.dart';
import 'package:pub_dev/admin/backend.dart';
import 'package:pub_dev/shared/configuration.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../../service/rate_limit/rate_limit.dart';
import '../../account/backend.dart';
import '../../admin/models.dart';
import '../../frontend/email_sender.dart';
import '../../frontend/handlers/cache_control.dart';
import '../../package/backend.dart';
import '../../publisher/backend.dart';
import '../../shared/datastore.dart';
import '../../shared/email.dart';
import '../../shared/exceptions.dart';
import '../../shared/handlers.dart';
import '../../shared/utils.dart';
import '../request_context.dart';
import '../templates/report.dart';

/// The number of requests allowed over [_reportRateLimitWindow]
const _reportRateLimit = 5;
const _reportRateLimitWindow = Duration(minutes: 10);
const _reportRateLimitWindowAsText = 'last 10 minutes';

/// Handles GET /report
Future<shelf.Response> reportPageHandler(shelf.Request request) async {
  if (!requestContext.experimentalFlags.isReportPageEnabled) {
    return notFoundHandler(request);
  }

  final subjectParam = request.requestedUri.queryParameters['subject'];
  InvalidInputException.checkNotNull(subjectParam, 'subject');
  final subject = ModerationSubject.tryParse(subjectParam!);
  InvalidInputException.check(subject != null, 'Invalid "subject" parameter.');
  await _verifySubject(subject!);

  final url = request.requestedUri.queryParameters['url'];
  _verifyUrl(url);

  final caseId = request.requestedUri.queryParameters['appeal'];
  await _verifyCaseId(caseId, subject);

  return htmlResponse(
    renderReportPage(
      sessionData: requestContext.sessionData,
      subject: subject,
      url: url,
      caseId: caseId,
    ),
    headers: CacheControl.explicitlyPrivate.headers,
  );
}

Future<void> _verifySubject(ModerationSubject? subject) async {
  final package = subject?.package;
  final version = subject?.version;
  if (package != null) {
    final p = await packageBackend.lookupPackage(package);
    if (p == null) {
      throw NotFoundException('Package "$package" does not exist.');
    }
    if (version != null) {
      final pv = await packageBackend.lookupPackageVersion(package, version);
      if (pv == null) {
        throw NotFoundException(
            'Package version "$package/$version" does not exist.');
      }
    }
  }

  final publisherId = subject?.publisherId;
  if (publisherId != null) {
    final p = await publisherBackend.getPublisher(publisherId);
    if (p == null) {
      throw NotFoundException('Publisher "$publisherId" does not exist.');
    }
  }

  final email = subject?.email;
  if (email != null) {
    InvalidInputException.check(
        isValidEmail(email), '"$email" is not a valid email.');

    // NOTE: We are not going to lookup and reject the requests based on the
    //       email address, as it would leak the existence of user accounts.
  }
}

void _verifyUrl(String? urlParam) {
  if (urlParam != null) {
    InvalidInputException.check(
      urlParam.startsWith(activeConfiguration.primarySiteUri.toString()),
      'Invalid "url" parameter.',
    );
    InvalidInputException.check(
      Uri.tryParse(urlParam) != null,
      'Invalid "url" parameter.',
    );
  }
}

Future<void> _verifyCaseId(String? caseId, ModerationSubject subject) async {
  if (caseId == null) {
    return null;
  }

  final mc = await adminBackend.lookupModerationCase(caseId);
  if (mc == null) {
    throw NotFoundException.resource('case_id "$caseId"');
  }
  InvalidInputException.check(mc.status != ModerationStatus.pending,
      'The reported case is not closed yet.');

  final hasSubject = mc.subject == subject.fqn ||
      mc.getActionLog().entries.any((e) => e.subject == subject.fqn);
  InvalidInputException.check(hasSubject,
      'The reported case has no resolution on subject "${subject.fqn}".');
}

/// Handles POST /api/report
Future<String> processReportPageHandler(
    shelf.Request request, ReportForm form) async {
  if (!requestContext.experimentalFlags.isReportPageEnabled) {
    throw NotFoundException('Experimental flag is not enabled.');
  }

  final sourceIp = request.sourceIp;
  if (sourceIp != null) {
    await verifyRequestCounts(
      sourceIp: sourceIp,
      operation: 'report',
      limit: _reportRateLimit,
      window: _reportRateLimitWindow,
      windowAsText: _reportRateLimitWindowAsText,
    );
  }

  final now = clock.now().toUtc();
  final caseId = '${now.toIso8601String().split('T').first}/${createUuid()}';

  final isAuthenticated = requestContext.sessionData?.isAuthenticated ?? false;
  final user = isAuthenticated ? await requireAuthenticatedWebUser() : null;
  final userEmail = user?.email ?? form.email;

  if (!isAuthenticated) {
    InvalidInputException.check(
      userEmail != null && isValidEmail(userEmail),
      'Email is invalid or missing.',
    );
  } else {
    InvalidInputException.checkNull(form.email, 'email');
  }

  InvalidInputException.checkNotNull(form.subject, 'subject');
  final subject = ModerationSubject.tryParse(form.subject!);
  InvalidInputException.check(subject != null, 'Invalid subject.');
  await _verifySubject(subject!);

  _verifyUrl(form.url);
  await _verifyCaseId(form.caseId, subject);

  InvalidInputException.checkStringLength(
    form.message,
    'message',
    minimum: 20,
    maximum: 8192,
  );

  final isAppeal = form.caseId != null;

  // If the email sending fails, we may have pending [ModerationCase] entities
  // in the datastore. These would be reviewed and processed manually.
  await withRetryTransaction(dbService, (tx) async {
    final mc = ModerationCase.init(
      caseId: caseId,
      reporterEmail: userEmail!,
      source: ModerationDetectedBy.externalNotification,
      kind: isAppeal ? ModerationKind.appeal : ModerationKind.notification,
      status: ModerationStatus.pending,
      subject: subject.fqn,
      url: form.url,
      appealedCaseId: form.caseId,
    );
    tx.insert(mc);
  });

  final kind = isAppeal ? 'appeal' : 'report';
  final bodyText = <String>[
    'New $kind received on ${now.toIso8601String()}: $caseId',
    if (form.url != null) 'URL: ${form.url}',
    if (isAppeal) 'Appealed case ID: ${form.caseId}',
    'Subject: ${subject.fqn}',
    'Message:\n${form.message}',
  ].join('\n\n');

  await emailSender.sendMessage(createReportPageAdminEmail(
    id: caseId,
    userEmail: userEmail!,
    bodyText: bodyText,
  ));

  return 'The $kind was submitted successfully.';
}
