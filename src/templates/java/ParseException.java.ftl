/* Generated by: ${generated_by}. ${filename} ${settings.copyrightBlurb} */

package ${settings.parserPackage};

#var BASE_EXCEPTION_TYPE = settings.useCheckedException?string("Exception", "RuntimeException")
#var TOKEN_TYPE_SET = "EnumSet<TokenType>", BaseToken = settings.baseTokenClassName, BaseTokenType = "TokenType"
#if settings.treeBuildingEnabled || settings.rootAPIPackage
  #set TOKEN_TYPE_SET = "Set<? extends Node.NodeType>"
  #set BaseToken = "Node.TerminalNode"
  #set BaseTokenType = "Node.NodeType"
#else
  import ${settings.parserPackage}.${BaseToken}.TokenType;
/#if

import java.util.*;

public class ParseException extends ${BASE_EXCEPTION_TYPE} {

  // The token we tripped up on.
  private ${BaseToken} token;
  //We were expecting one of these token types
  private ${TOKEN_TYPE_SET} expectedTypes;
  
  private List<NonTerminalCall> callStack;
  
  private boolean alreadyAdjusted;

  private void setInfo(${BaseToken} token, ${TOKEN_TYPE_SET} expectedTypes, List<NonTerminalCall> callStack) {
    if (token != null && !token.getType().isEOF() && token.getNext() != null) {
        token = token.getNext();
    }
    this.token = token;
    this.expectedTypes = expectedTypes;
    this.callStack = new ArrayList<>(callStack);
  }

  public boolean hitEOF() {
    return token != null && token.getType().isEOF();
  }

  public ParseException(${BaseToken} token, ${TOKEN_TYPE_SET} expectedTypes, List<NonTerminalCall> callStack) {
      setInfo(token, expectedTypes, callStack);
  }

  public ParseException(${BaseToken} token) {
     this.token = token;
  }

  public ParseException() {}
  
  // Needed because of inheritance
  public ParseException(String message) {
    super(message);
  }

  public ParseException(String message, List<NonTerminalCall> callStack) {
    super(message);
    this.callStack = callStack;
  }

  public ParseException(String message, ${BaseToken} token, List<NonTerminalCall> callStack) {
     super(message);
     this.token = token;
     this.callStack = callStack;
  }
  
  @Override 
  public String getMessage() {
     String msg = super.getMessage();
     if (token == null && expectedTypes == null) {
        return msg;
     }
     StringBuilder buf = new StringBuilder();
     if (msg != null) buf.append(msg);
     String location = token != null ? token.getLocation() : "";
     buf.append("\nEncountered an error at (or somewhere around) " + location);
     if  (expectedTypes != null && token!=null && expectedTypes.contains(token.getType())) {
         [#-- //This is really screwy, have to revisit this whole case. --]
         return buf.toString();
     }
     if (expectedTypes != null) {
         buf.append("\nWas expecting one of the following:\n");
         boolean isFirst = true;
         for (${BaseTokenType} type : expectedTypes) {
             if (!isFirst) buf.append(", ");
             isFirst = false;
             buf.append(type);
         }
     }
     String content = token.toString();
     if (content == null) content = "";
     if (content.length() > 32) content = content.substring(0, 32) + "...";
     buf.append("\nFound string \"" + addEscapes(content) + "\" of type " + token.getType());
     return buf.toString();
  }
  
  @Override
  public StackTraceElement[] getStackTrace() {
      adjustStackTrace();
      return super.getStackTrace();
  }
  
  @Override
  public void printStackTrace(java.io.PrintStream s) {
        adjustStackTrace();
        super.printStackTrace(s);
  }

  /**
   * Returns the token which causes the parse error and null otherwise.
   * @return the token which causes the parse error and null otherwise.
   */
   public ${BaseToken} getToken() {
      return token;
   }
  
   private void adjustStackTrace() {
      if (alreadyAdjusted || callStack == null || callStack.isEmpty()) return;
      List<StackTraceElement> fullTrace = new ArrayList<>();
      List<StackTraceElement> ourCallStack = new ArrayList<>();
      for (NonTerminalCall ntc : callStack) {
         ourCallStack.add(ntc.createStackTraceElement());
      }
      StackTraceElement[] jvmCallStack = super.getStackTrace();
      for (StackTraceElement regularEntry : jvmCallStack) {
           if (ourCallStack.isEmpty()) break;
           String methodName = regularEntry.getMethodName();
           StackTraceElement ourEntry = lastElementWithName(ourCallStack, methodName);
           if (ourEntry!= null) {
               fullTrace.add(ourEntry);
           }
           fullTrace.add(regularEntry);
      }
      StackTraceElement[] result = new StackTraceElement[fullTrace.size()];
      setStackTrace(fullTrace.toArray(result));
      alreadyAdjusted = true;
  }
  
  private StackTraceElement lastElementWithName(List<StackTraceElement> elements, String methodName) {
      for (ListIterator<StackTraceElement> it = elements.listIterator(elements.size()); it.hasPrevious();) {
           StackTraceElement elem = it.previous();
           if (elem.getMethodName().equals(methodName)) {
                it.remove();
                return elem;
           }
      }
      return null;
  }

  private static String addEscapes(String str) {
      StringBuilder retval = new StringBuilder();
      for (int ch : str.codePoints().toArray()) {
        switch (ch) {
           case '\b':
              retval.append("\\b");
              continue;
           case '\t':
              retval.append("\\t");
              continue;
           case '\n':
              retval.append("\\n");
              continue;
           case '\f':
              retval.append("\\f");
              continue;
           case '\r':
              retval.append("\\r");
              continue;
           case '\"':
              retval.append("\\\"");
              continue;
           case '\'':
              retval.append("\\\'");
              continue;
           case '\\':
              retval.append("\\\\");
              continue;
           default:
              if (Character.isISOControl(ch)) {
                 String s = "0000" + java.lang.Integer.toString(ch, 16);
                 retval.append("\\u" + s.substring(s.length() - 4, s.length()));
              } else {
                 retval.appendCodePoint(ch);
              }
              continue;
        }
      }
      return retval.toString();
  }
}
