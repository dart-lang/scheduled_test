// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:stack_trace/stack_trace.dart';

import 'future_group.dart';
import 'schedule.dart';
import 'utils.dart';

typedef Future<T> TaskBody<T>();

/// A single task to be run as part of a [TaskQueue].
///
/// There are two levels of tasks. **Top-level tasks** are created by calling
/// [TaskQueue.schedule] before the queue in question is running. They're run in
/// sequence as part of that [TaskQueue]. **Nested tasks** are created by
/// calling [TaskQueue.schedule] once the queue is already running, and are run
/// in parallel as part of a top-level task.
class Task<T> {
  /// The queue to which this [Task] belongs.
  final TaskQueue queue;

  /// Child tasks that have been spawned while running this task. This will be
  /// empty if this task is a nested task.
  List<Task> get children => new UnmodifiableListView(_children);
  final _children = new Queue<Task>();

  /// A [FutureGroup] that will complete once all current child tasks are
  /// finished running. This will be null if no child tasks are currently
  /// running.
  FutureGroup _childGroup;

  /// A description of this task. Used for debugging. May be `null`.
  final String description;

  /// The parent task, if this is a nested task that was started while another
  /// task was running. This will be `null` for top-level tasks.
  final Task parent;

  /// The body of the task.
  TaskBody<T> fn;

  /// The current state of [this].
  TaskState get state => _state;
  var _state = TaskState.WAITING;

  /// The identifier of the task. For top-level tasks, this is the index of the
  /// task within [queue]; for nested tasks, this is the index within
  /// [parent.children]. It's used for debugging when [description] isn't
  /// provided.
  int _id;

  /// A Future that will complete to the return value of [fn] once this task
  /// finishes running.
  Future<T> get result => _resultCompleter.future;
  final _resultCompleter = new Completer<T>();

  final Chain stackChain;

  Task(fn(), String description, TaskQueue queue)
      : this._(fn, description, queue, null, queue.contents.length);

  Task._child(fn(), String description, Task parent)
      : this._(fn, description, parent.queue, parent, parent.children.length);

  Task._(fn(), this.description, TaskQueue queue, this.parent, this._id)
      : queue = queue,
        stackChain = new Chain.current() {
    this.fn = () {
      if (state != TaskState.WAITING) {
        throw new StateError("Can't run $state task '$this'.");
      }

      _state = TaskState.RUNNING;
      var future = new Future<T>.sync(fn).then<T>((value) {
        if (_childGroup == null || _childGroup.completed) return value;
        return _childGroup.future.then((_) => value);
      });
      chainToCompleter(future, _resultCompleter);
      return future;
    };

    result.then((_) {
      _state = TaskState.SUCCESS;
    }).catchError((_) {
      _state = TaskState.ERROR;
    });
  }

  /// Run [fn] as a child of this task. Returns a Future that will complete with
  /// the result of the child task. This task will not complete until [fn] has
  /// finished.
  Future<S> runChild<S>(TaskBody<S> fn, String description) {
    var task = new Task<S>._child(fn, description, this);
    _children.add(task);
    if (_childGroup == null || _childGroup.completed) {
      _childGroup = new FutureGroup();
    }
    _childGroup.add(task.result);
    task.fn();
    return task.result;
  }

  String toString() => description == null ? "#$_id" : description;

  String toStringWithStackTrace() {
    var stackString = prefixLines(terseTraceString(stackChain));
    return "$this\n\nStack chain:\n$stackString";
  }

  /// Returns a detailed representation of [queue] with this task highlighted.
  String generateTree() => queue.generateTree(this);
}

/// An enum of states for a [Task].
class TaskState {
  /// The task is waiting to be run.
  static const WAITING = const TaskState._("WAITING");

  /// The task is currently running.
  static const RUNNING = const TaskState._("RUNNING");

  /// The task has finished running successfully.
  static const SUCCESS = const TaskState._("SUCCESS");

  /// The task has finished running with an error.
  static const ERROR = const TaskState._("ERROR");

  /// The name of the state.
  final String name;

  /// Whether the state indicates that the task has finished running. This is
  /// true for both the [SUCCESS] and [ERROR] states.
  bool get isDone => this == SUCCESS || this == ERROR;

  const TaskState._(this.name);

  String toString() => name;
}
