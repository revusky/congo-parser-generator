package org.congocc.codegen.java;

import org.congocc.parser.*;
import org.congocc.parser.tree.*;

class CurrentNodeMunger extends Node.Visitor {

    private int nodeNumbering;

    private String currentNodeName = "thisProduction";
    private CodeBlock currentBlock;

    void visit(CodeBlock block) {
        CodeBlock prevBlock = this.currentBlock;
        this.currentBlock = block;
        String prevNodeName = currentNodeName;
        recurse(block);
        this.currentBlock = prevBlock;
        currentNodeName = prevNodeName;
    }

    void visit(MethodDeclaration md) {
        nodeNumbering = 0;
        recurse(md);
    }

    void visit(VariableDeclarator vd) {
        if (!(vd.getParent() instanceof NoVarDeclaration)) return;
        Identifier id = vd.firstDescendantOfType(Identifier.class, ident->ident.toString().equals("CURRENT_NODE"));
        if (id != null) {
            currentNodeName = "$currentNode$" + nodeNumbering;
            id.setCachedImage(currentNodeName);
            nodeNumbering++;
        }
    }

    void visit(Identifier id) {
        if (currentBlock == null) return;
        if (id.toString().equals("CURRENT_NODE")) {
            id.setCachedImage(currentNodeName);
        }
    }
}