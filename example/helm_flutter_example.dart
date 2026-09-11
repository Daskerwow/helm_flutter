class Demo {
  bool _busy = false;

  void run(void Function() sideEffect) {
    if (_busy) {
      print('заблокировано — уже внутри run()');
      return;
    }
    _busy = true;
    print('вошли в run(), _busy = true');

    sideEffect(); // может СИНХРОННО вызвать run() ещё раз

    _busy = false;
    print('вышли из run(), _busy = false');
  }
}

void main() {
  final d = Demo();
  d.run(() {
    print('sideEffect начал работу');
    d.run(() => print('этого не будет')); // вложенный вызов ДО finally
    print('sideEffect закончил');
  });
}
